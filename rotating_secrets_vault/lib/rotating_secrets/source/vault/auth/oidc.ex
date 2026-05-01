defmodule RotatingSecrets.Source.Vault.Auth.Oidc do
  @moduledoc """
  Generic OIDC client_credentials authentication adapter for OpenBao/Vault.

  Authenticates to any OIDC provider (Zitadel, Keycloak, etc.) using the
  OAuth2 client_credentials grant, then exchanges the resulting access token
  for an OpenBao Vault client token via the JWT auth method.

  Starts an anonymous `Oidcc.ProviderConfiguration.Worker` linked to the
  calling process. This is intentionally fail-fast: if the OIDC provider is
  unreachable at startup or crashes during JWKS refresh, the rotating_secrets
  process also crashes (same philosophy as `jwt_svid.ex`).
  """

  alias RotatingSecrets.Source.Vault.HTTP

  @refresh_buffer_secs 30
  @short_ttl_threshold_secs 60

  @type auth_state :: %{
          oidcc_provider: pid(),
          client_id: String.t(),
          client_secret: String.t(),
          role: String.t(),
          mount: String.t(),
          vault_token: String.t() | nil,
          token_expires_at: DateTime.t(),
          oidc_token: String.t() | nil,
          oidc_token_expires_at: DateTime.t()
        }

  @spec init(keyword(), Req.Request.t()) :: {:ok, auth_state()} | {:error, term()}
  def init(opts, base_req) do
    with {:ok, issuer_uri} <- fetch_required_string(opts, :issuer_uri),
         {:ok, client_id} <- fetch_required_string(opts, :client_id),
         {:ok, client_secret} <- fetch_required_string(opts, :client_secret),
         {:ok, role} <- fetch_required_string(opts, :role) do
      mount = Keyword.get(opts, :mount, "jwt")

      {:ok, provider_pid} =
        Oidcc.ProviderConfiguration.Worker.start_link(%{issuer: issuer_uri})

      auth_state = %{
        oidcc_provider: provider_pid,
        client_id: client_id,
        client_secret: client_secret,
        role: role,
        mount: mount,
        vault_token: nil,
        token_expires_at: ~U[1970-01-01 00:00:00Z],
        oidc_token: nil,
        oidc_token_expires_at: ~U[1970-01-01 00:00:00Z]
      }

      with {:ok, auth_with_oidc} <- fetch_oidc_token(auth_state) do
        login(auth_with_oidc, base_req)
      end
    end
  end

  @spec ensure_fresh(auth_state(), Req.Request.t()) ::
          {:ok, Req.Request.t(), auth_state()} | {:error, term()}
  def ensure_fresh(auth_state, base_req) do
    vault_near_expiry = near_expiry?(auth_state.token_expires_at)
    oidc_near_expiry = near_expiry?(auth_state.oidc_token_expires_at)

    cond do
      not vault_near_expiry ->
        {:ok, inject_token(base_req, auth_state.vault_token), auth_state}

      vault_near_expiry and not oidc_near_expiry ->
        case login(auth_state, base_req) do
          {:ok, new_auth} -> {:ok, inject_token(base_req, new_auth.vault_token), new_auth}
          error -> error
        end

      true ->
        with {:ok, new_auth} <- fetch_oidc_token(auth_state),
             {:ok, final_auth} <- login(new_auth, base_req) do
          {:ok, inject_token(base_req, final_auth.vault_token), final_auth}
        end
    end
  end

  defp fetch_oidc_token(auth_state) do
    start = System.monotonic_time(:millisecond)

    case :oidcc.client_credentials_token(
           auth_state.oidcc_provider,
           auth_state.client_id,
           auth_state.client_secret,
           %{}
         ) do
      {:ok, token} ->
        access_token = token.access.token

        expires_at =
          case Map.get(token, :extra_fields, %{}) do
            %{"expires_in" => secs} -> DateTime.add(DateTime.utc_now(), secs, :second)
            _ -> DateTime.add(DateTime.utc_now(), 3600, :second)
          end

        duration_ms = System.monotonic_time(:millisecond) - start

        :telemetry.execute(
          [:rotating_secrets, :vault, :oidc, :token_refresh],
          %{duration_ms: duration_ms},
          %{result: :ok}
        )

        {:ok, %{auth_state | oidc_token: access_token, oidc_token_expires_at: expires_at}}

      {:error, _reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start

        :telemetry.execute(
          [:rotating_secrets, :vault, :oidc, :token_refresh],
          %{duration_ms: duration_ms},
          %{result: :error}
        )

        {:error, :oidc_token_failed}
    end
  end

  defp login(auth_state, base_req) do
    start = System.monotonic_time(:millisecond)

    case HTTP.post(base_req, "/v1/auth/#{auth_state.mount}/login", %{
           "jwt" => auth_state.oidc_token,
           "role" => auth_state.role
         }) do
      {:ok, %{"auth" => %{"client_token" => token, "lease_duration" => ttl}}} ->
        duration_ms = System.monotonic_time(:millisecond) - start

        if ttl < @short_ttl_threshold_secs do
          :telemetry.execute(
            [:rotating_secrets, :vault, :oidc, :short_ttl_warning],
            %{lease_duration: ttl},
            %{}
          )
        end

        :telemetry.execute(
          [:rotating_secrets, :vault, :oidc, :login],
          %{duration_ms: duration_ms},
          %{result: :ok, reason: nil}
        )

        token_expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)
        {:ok, %{auth_state | vault_token: token, token_expires_at: token_expires_at}}

      {:ok, _other} ->
        duration_ms = System.monotonic_time(:millisecond) - start

        :telemetry.execute(
          [:rotating_secrets, :vault, :oidc, :login],
          %{duration_ms: duration_ms},
          %{result: :error, reason: :vault_login_malformed_response}
        )

        {:error, :vault_login_malformed_response}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start

        :telemetry.execute(
          [:rotating_secrets, :vault, :oidc, :login],
          %{duration_ms: duration_ms},
          %{result: :error, reason: reason}
        )

        {:error, reason}
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
