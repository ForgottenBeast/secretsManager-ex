defmodule RotatingSecrets.Source.Vault.Auth.ZitadelOidc do
  @moduledoc """
  Zitadel OIDC authentication adapter for OpenBao/Vault via SpiffeEx.

  Delegates to `SpiffeEx.authenticate/1` to obtain a Zitadel OIDC access token,
  then exchanges it for a Vault client token via the JWT auth method login
  endpoint. The full SPIRE JWT-SVID → Zitadel OIDC token exchange is managed
  internally by SpiffeEx.TokenCache; this adapter only tracks the OpenBao vault
  token expiry.

  NOTE: `init/2` performs blocking I/O (SpiffeEx.authenticate + Vault login).
  This is intentional to fail-fast on bad credentials or an unavailable SPIRE
  agent at startup.
  """

  alias RotatingSecrets.Source.Vault.HTTP

  @refresh_buffer_secs 30
  @short_ttl_threshold_secs 60

  @type auth_state :: %{
          spiffe_ex: atom(),
          role: String.t(),
          mount: String.t(),
          vault_token: String.t() | nil,
          token_expires_at: DateTime.t(),
          authenticate_fn: (atom() -> {:ok, SpiffeEx.Token.t()} | {:error, atom()})
        }

  @spec init(keyword(), Req.Request.t()) :: {:ok, auth_state()} | {:error, term()}
  def init(opts, base_req) do
    with {:ok, spiffe_ex} <- fetch_required_atom(opts, :spiffe_ex),
         {:ok, role} <- fetch_required_string(opts, :role) do
      mount = Keyword.get(opts, :mount, "jwt")
      authenticate_fn = Keyword.get(opts, :authenticate_fn, &SpiffeEx.authenticate/1)

      auth_state = %{
        spiffe_ex: spiffe_ex,
        role: role,
        mount: mount,
        vault_token: nil,
        token_expires_at: ~U[1970-01-01 00:00:00Z],
        authenticate_fn: authenticate_fn
      }

      login(auth_state, base_req)
    end
  end

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

  defp login(auth_state, base_req) do
    start = System.monotonic_time(:millisecond)

    case auth_state.authenticate_fn.(auth_state.spiffe_ex) do
      {:ok, %SpiffeEx.Token{access_token: jwt}} ->
        case HTTP.post(base_req, "/v1/auth/#{auth_state.mount}/login", %{
               "jwt" => jwt,
               "role" => auth_state.role
             }) do
          {:ok, %{"auth" => %{"client_token" => token, "lease_duration" => ttl}}} ->
            duration_ms = System.monotonic_time(:millisecond) - start

            if ttl < @short_ttl_threshold_secs do
              :telemetry.execute(
                [:rotating_secrets, :vault, :zitadel_oidc, :short_ttl_warning],
                %{lease_duration: ttl},
                %{}
              )
            end

            :telemetry.execute(
              [:rotating_secrets, :vault, :zitadel_oidc, :login],
              %{duration_ms: duration_ms},
              %{result: :ok, reason: nil}
            )

            token_expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)
            {:ok, %{auth_state | vault_token: token, token_expires_at: token_expires_at}}

          {:ok, _other} ->
            duration_ms = System.monotonic_time(:millisecond) - start

            :telemetry.execute(
              [:rotating_secrets, :vault, :zitadel_oidc, :login],
              %{duration_ms: duration_ms},
              %{result: :error, reason: :vault_login_malformed_response}
            )

            {:error, :vault_login_malformed_response}

          {:error, reason} ->
            duration_ms = System.monotonic_time(:millisecond) - start

            :telemetry.execute(
              [:rotating_secrets, :vault, :zitadel_oidc, :login],
              %{duration_ms: duration_ms},
              %{result: :error, reason: reason}
            )

            {:error, reason}
        end

      {:error, _reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start

        :telemetry.execute(
          [:rotating_secrets, :vault, :zitadel_oidc, :login],
          %{duration_ms: duration_ms},
          %{result: :error, reason: :spiffe_agent_unavailable}
        )

        {:error, :spiffe_agent_unavailable}
    end
  end

  defp near_expiry?(expires_at) do
    DateTime.diff(expires_at, DateTime.utc_now(), :second) <= @refresh_buffer_secs
  end

  defp inject_token(base_req, token) do
    Req.merge(base_req, headers: [{"x-vault-token", token}])
  end

  defp fetch_required_atom(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} when is_atom(val) -> {:ok, val}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp fetch_required_string(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} when is_binary(val) and byte_size(val) > 0 -> {:ok, val}
      _ -> {:error, {:invalid_option, key}}
    end
  end
end
