defmodule RotatingSecrets.Source.Vault.Auth.ZitadelPrivateKeyJwt do
  @moduledoc """
  Zitadel `private_key_jwt` authentication adapter for OpenBao/Vault.

  Implements the machine-to-machine auth chain validated for the SPIRE →
  Zitadel → OpenBao actor architecture:

  1. Read the RSA key JSON from OpenBao KV at `key_kv_path` using the caller-supplied
     bootstrap request (which already carries a token obtained via SPIRE JWT-SVID auth).
  2. Build a self-signed JWT assertion: `iss = sub = userId`, signed with the RSA
     private key. Zitadel requires `iss == sub` — this is satisfied because the
     machine user asserts its own Zitadel user ID.
  3. POST the assertion to Zitadel with `grant_type=jwt-bearer`. Zitadel validates
     the signature against the registered public key and returns an `access_token`
     whose `aud` claim contains the machine user's username.
  4. POST the Zitadel `access_token` to OpenBao `auth/{vault_mount}/login` with the
     configured `vault_role`. OpenBao validates `aud` against `bound_audiences` and
     returns a scoped `client_token`.

  ## Why `private_key_jwt` instead of SPIRE JWT-SVIDs directly

  RFC 7523 jwt-bearer with SPIRE SVIDs is fundamentally incompatible with Zitadel:
  Zitadel requires `iss == sub` in the client assertion, but SPIRE SVIDs always have
  `iss = OIDC_discovery_URL` and `sub = spiffe://...` — always different. This is not
  a configuration issue. See the migration runbook for details.

  ## Key JSON format

  The `key_json` field stored in OpenBao KV must be a JSON string with the structure
  produced by `zitadel-setup.sh`:

      {"type":"serviceaccount","keyId":"<zitadel_key_id>","key":"<RSA_PEM>","userId":"<zitadel_user_id>"}

  ## Options

    * `:zitadel_url` — Zitadel base URL, e.g. `"https://homeserver:8443"`. Required.
    * `:key_kv_path` — Full OpenBao KV v2 API path to the key secret, e.g.
      `"secret/data/normatix/zitadel-machine-key"`. Required.
    * `:vault_role` — OpenBao JWT auth role to login with, e.g. `"normatix-machine"`. Required.
    * `:vault_mount` — OpenBao JWT auth mount. Defaults to `"jwt"` (Zitadel tokens),
      NOT `"jwt-spire"` (SPIRE SVIDs used by the JwtSvid adapter). Required for clarity.
    * `:zitadel_req_opts` — Extra keyword options merged into the `Req.new/1` call used
      for the Zitadel token exchange. Common uses:
      - Self-signed cert: `[connect_options: [verify: :verify_none]]`
      - Private CA: `[connect_options: [cacertfile: "/path/to/ca.pem"]]`
      - Test stub: `[plug: {Req.Test, :my_stub}]`
      Defaults to `[]`.

  ## Auth state

  The `auth_state` map caches the parsed RSA key so `ensure_fresh/2` can re-sign
  without re-reading OpenBao KV. The caller (GenServer or equivalent) is responsible
  for holding this state between calls.
  """

  alias RotatingSecrets.Source.Vault.HTTP

  @grant_type_jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @refresh_buffer_secs 30
  @short_ttl_threshold_secs 60
  # Assertion JWT lifetime. Short-lived: one-time-use for token exchange.
  @assertion_exp_secs 300

  @type rsa_key :: :public_key.rsa_private_key()

  @type auth_state :: %{
          zitadel_url: String.t(),
          key_kv_path: String.t(),
          vault_role: String.t(),
          vault_mount: String.t(),
          zitadel_req_opts: keyword(),
          parsed_key: %{user_id: String.t(), key_id: String.t(), rsa_key: rsa_key()},
          vault_token: String.t() | nil,
          token_expires_at: DateTime.t()
        }

  @doc """
  Initialises the auth state by reading the RSA key from OpenBao KV and performing
  the full private_key_jwt → Zitadel → OpenBao login chain.

  `base_req` must carry a bootstrap OpenBao token with read access to `key_kv_path`.
  This token is typically obtained via SPIRE JWT-SVID auth (`Auth.JwtSvid`) before
  calling this adapter.
  """
  @spec init(keyword(), Req.Request.t()) :: {:ok, auth_state()} | {:error, term()}
  def init(opts, base_req) do
    with {:ok, zitadel_url} <- fetch_required_string(opts, :zitadel_url),
         {:ok, key_kv_path} <- fetch_required_string(opts, :key_kv_path),
         {:ok, vault_role} <- fetch_required_string(opts, :vault_role) do
      vault_mount = Keyword.get(opts, :vault_mount, "jwt")
      zitadel_req_opts = Keyword.get(opts, :zitadel_req_opts, [])

      auth_state = %{
        zitadel_url: zitadel_url,
        key_kv_path: key_kv_path,
        vault_role: vault_role,
        vault_mount: vault_mount,
        zitadel_req_opts: zitadel_req_opts,
        parsed_key: nil,
        vault_token: nil,
        token_expires_at: ~U[1970-01-01 00:00:00Z]
      }

      with {:ok, parsed_key} <- read_and_parse_key(base_req, key_kv_path),
           {:ok, new_auth} <- login(%{auth_state | parsed_key: parsed_key}, base_req) do
        {:ok, new_auth}
      end
    end
  end

  @doc """
  Returns a fresh OpenBao-authed request, re-running the full Zitadel exchange if
  the vault token is near expiry. The RSA key is read from cached state — no KV
  re-read.
  """
  @spec ensure_fresh(auth_state(), Req.Request.t()) ::
          {:ok, Req.Request.t(), auth_state()} | {:error, term()}
  def ensure_fresh(auth_state, base_req) do
    if near_expiry?(auth_state.token_expires_at) do
      case login(auth_state, base_req) do
        {:ok, new_auth} -> {:ok, inject_token(base_req, new_auth.vault_token), new_auth}
        error -> error
      end
    else
      {:ok, inject_token(base_req, auth_state.vault_token), auth_state}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  # Read key_json from OpenBao KV and parse it into %{user_id, key_id, rsa_key}.
  defp read_and_parse_key(base_req, key_kv_path) do
    case HTTP.get(base_req, "/v1/#{key_kv_path}") do
      {:ok, %{"data" => %{"data" => %{"key_json" => key_json_str}}}} ->
        parse_key_json(key_json_str)

      {:ok, _other} ->
        {:error, :zitadel_key_malformed_kv_response}

      {:error, :vault_secret_not_found} ->
        # First-deploy race: zitadel-setup has not run yet.
        {:error, {:zitadel_key_not_found, key_kv_path}}

      {:error, reason} ->
        {:error, {:zitadel_key_read_failed, reason}}
    end
  end

  # Parse the key_json string produced by zitadel-setup.sh:
  # {"type":"serviceaccount","keyId":"...","key":"-----BEGIN RSA...","userId":"..."}
  defp parse_key_json(key_json_str) when is_binary(key_json_str) do
    with {:ok, %{"keyId" => key_id, "key" => pem, "userId" => user_id}} <-
           Jason.decode(key_json_str),
         {:ok, rsa_key} <- parse_rsa_pem(pem) do
      {:ok, %{user_id: user_id, key_id: key_id, rsa_key: rsa_key}}
    else
      {:ok, _} -> {:error, :zitadel_key_missing_fields}
      {:error, %Jason.DecodeError{}} -> {:error, :zitadel_key_json_decode_failed}
      {:error, _} = err -> err
    end
  end

  defp parse_key_json(_), do: {:error, :zitadel_key_json_not_a_string}

  defp parse_rsa_pem(pem) do
    case :public_key.pem_decode(pem) do
      [{:RSAPrivateKey, der, _}] ->
        {:ok, :public_key.der_decode(:RSAPrivateKey, der)}

      [] ->
        {:error, :zitadel_key_invalid_pem}

      _ ->
        {:error, :zitadel_key_unexpected_pem_type}
    end
  end

  # Full login chain: sign assertion JWT → exchange with Zitadel → login to OpenBao.
  defp login(auth_state, base_req) do
    start = System.monotonic_time(:millisecond)

    with {:ok, assertion_jwt} <- build_assertion_jwt(auth_state),
         {:ok, zitadel_token} <-
           exchange_with_zitadel(assertion_jwt, auth_state.zitadel_url, auth_state.zitadel_req_opts),
         {:ok, vault_token, ttl} <-
           login_to_openbao(zitadel_token, auth_state.vault_role, auth_state.vault_mount, base_req) do
      duration_ms = System.monotonic_time(:millisecond) - start

      if ttl < @short_ttl_threshold_secs do
        :telemetry.execute(
          [:rotating_secrets, :vault, :zitadel_private_key_jwt, :short_ttl_warning],
          %{lease_duration: ttl},
          %{}
        )
      end

      :telemetry.execute(
        [:rotating_secrets, :vault, :zitadel_private_key_jwt, :login],
        %{duration_ms: duration_ms},
        %{result: :ok, vault_role: auth_state.vault_role}
      )

      token_expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)
      {:ok, %{auth_state | vault_token: vault_token, token_expires_at: token_expires_at}}
    else
      {:error, reason} = err ->
        duration_ms = System.monotonic_time(:millisecond) - start

        :telemetry.execute(
          [:rotating_secrets, :vault, :zitadel_private_key_jwt, :login],
          %{duration_ms: duration_ms},
          %{result: :error, reason: reason, vault_role: auth_state.vault_role}
        )

        err
    end
  end

  # Build a self-signed JWT assertion for Zitadel private_key_jwt auth.
  #
  # aud claim explanation:
  #   - The assertion JWT sent TO Zitadel has aud=[zitadel_url, token_endpoint].
  #   - The access_token RETURNED BY Zitadel has aud=[machine_username] — this is
  #     what OpenBao's bound_audiences validates, not the assertion JWT's aud.
  defp build_assertion_jwt(%{zitadel_url: zitadel_url, parsed_key: parsed_key}) do
    %{user_id: user_id, key_id: key_id, rsa_key: rsa_key} = parsed_key
    token_endpoint = "#{zitadel_url}/oauth/v2/token"

    now = System.os_time(:second)

    header = %{"alg" => "RS256", "kid" => key_id}
    claims = %{
      "iss" => user_id,
      "sub" => user_id,
      "aud" => [zitadel_url, token_endpoint],
      "iat" => now,
      "exp" => now + @assertion_exp_secs
    }

    header_b64 = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    claims_b64 = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    signing_input = "#{header_b64}.#{claims_b64}"

    # :public_key.sign/3 accepts the decoded RSAPrivateKey record and uses
    # PKCS#1 v1.5 padding by default — correct for JWT RS256 (RSASSA-PKCS1-v1_5).
    # :crypto.sign/5 requires the key in list format [e, n, d, ...] which differs
    # from what :public_key.der_decode/2 returns.
    signature = :public_key.sign(signing_input, :sha256, rsa_key)

    sig_b64 = Base.url_encode64(signature, padding: false)
    {:ok, "#{signing_input}.#{sig_b64}"}
  rescue
    e -> {:error, {:jwt_signing_failed, Exception.message(e)}}
  end

  defp exchange_with_zitadel(assertion_jwt, zitadel_url, extra_req_opts) do
    body =
      URI.encode_query(%{
        "grant_type" => @grant_type_jwt_bearer,
        "assertion" => assertion_jwt,
        "scope" => "openid"
      })

    req = Req.new([retry: false, receive_timeout: 10_000] ++ extra_req_opts)

    case Req.post(req,
           url: "#{zitadel_url}/oauth/v2/token",
           headers: [{"content-type", "application/x-www-form-urlencoded"}],
           body: body
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error, {:zitadel_jwt_bearer_failed, status, body}}

      {:error, reason} ->
        {:error, {:zitadel_request_failed, reason}}
    end
  end

  defp login_to_openbao(zitadel_token, vault_role, vault_mount, base_req) do
    case HTTP.post(base_req, "/v1/auth/#{vault_mount}/login", %{
           "jwt" => zitadel_token,
           "role" => vault_role
         }) do
      {:ok, %{"auth" => %{"client_token" => token, "lease_duration" => ttl}}} ->
        {:ok, token, ttl}

      {:ok, _other} ->
        {:error, :openbao_login_malformed_response}

      {:error, reason} ->
        {:error, {:openbao_login_failed, reason}}
    end
  end

  defp near_expiry?(expires_at) do
    DateTime.diff(expires_at, DateTime.utc_now(), :second) <= @refresh_buffer_secs
  end

  defp inject_token(base_req, token) do
    Req.merge(base_req, headers: [{"x-vault-token", token}])
  end

  defp fetch_required_string(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} when is_binary(val) and byte_size(val) > 0 -> {:ok, val}
      _ -> {:error, {:invalid_option, key}}
    end
  end
end
