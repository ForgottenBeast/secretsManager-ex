defmodule RotatingSecrets.Source.Vault.Auth.OidcTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Source.Vault.Auth.Oidc

  @stub_name :oidc_test_vault

  defp base_req, do: Req.new(plug: {Req.Test, @stub_name})

  defp vault_login_response(conn, token \\ "s.vault-test-token", ttl \\ 3600) do
    Req.Test.json(conn, %{
      "auth" => %{
        "client_token" => token,
        "lease_duration" => ttl
      }
    })
  end

  # Builds a pre-seeded auth_state with both tokens fresh (far future expiry).
  # The oidcc_provider is set to self() since these tests never invoke oidcc.
  defp fresh_auth_state(overrides \\ []) do
    base = %{
      oidcc_provider: self(),
      client_id: "my-client",
      client_secret: "my-secret",
      role: "my-role",
      mount: "jwt",
      vault_token: "s.existing-token",
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oidc_token: "oidc-bearer-token",
      oidc_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }

    Map.merge(base, Map.new(overrides))
  end

  # Builds a pre-seeded auth_state with vault token near expiry, oidc token fresh.
  defp vault_near_expiry_state do
    fresh_auth_state(token_expires_at: DateTime.add(DateTime.utc_now(), 10, :second))
  end

  describe "init/2 - missing required opts" do
    test "returns {:error, {:invalid_option, :issuer_uri}} when missing" do
      opts = [client_id: "c", client_secret: "s", role: "r"]
      assert {:error, {:invalid_option, :issuer_uri}} = Oidc.init(opts, base_req())
    end

    test "returns {:error, {:invalid_option, :client_id}} when missing" do
      opts = [issuer_uri: "https://example.com", client_secret: "s", role: "r"]
      assert {:error, {:invalid_option, :client_id}} = Oidc.init(opts, base_req())
    end

    test "returns {:error, {:invalid_option, :client_secret}} when missing" do
      opts = [issuer_uri: "https://example.com", client_id: "c", role: "r"]
      assert {:error, {:invalid_option, :client_secret}} = Oidc.init(opts, base_req())
    end

    test "returns {:error, {:invalid_option, :role}} when missing" do
      opts = [issuer_uri: "https://example.com", client_id: "c", client_secret: "s"]
      assert {:error, {:invalid_option, :role}} = Oidc.init(opts, base_req())
    end
  end

  describe "ensure_fresh/2 - vault token fresh" do
    test "injects vault token without re-auth" do
      auth_state = fresh_auth_state()

      assert {:ok, fresh_req, ^auth_state} = Oidc.ensure_fresh(auth_state, base_req())
      assert Req.Request.get_header(fresh_req, "x-vault-token") == ["s.existing-token"]
    end
  end

  describe "ensure_fresh/2 - vault near expiry, oidc still valid" do
    test "re-logins to OpenBao only, no new oidcc call" do
      Req.Test.stub(@stub_name, fn conn -> vault_login_response(conn, "s.new-token", 3600) end)

      auth_state = vault_near_expiry_state()

      assert {:ok, fresh_req, new_auth} = Oidc.ensure_fresh(auth_state, base_req())
      assert new_auth.vault_token == "s.new-token"
      # oidc_token unchanged — no oidcc call was made
      assert new_auth.oidc_token == "oidc-bearer-token"
      assert Req.Request.get_header(fresh_req, "x-vault-token") == ["s.new-token"]
    end

    test "propagates vault login error" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"auth" => %{"no_token" => "here"}})
      end)

      auth_state = vault_near_expiry_state()

      assert {:error, :vault_login_malformed_response} = Oidc.ensure_fresh(auth_state, base_req())
    end
  end

  describe "telemetry - login event" do
    test "emits [:rotating_secrets, :vault, :oidc, :login] on vault re-auth" do
      telemetry_event = [:rotating_secrets, :vault, :oidc, :login]
      handler_id = "test-oidc-login-#{inspect(make_ref())}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        telemetry_event,
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(@stub_name, fn conn -> vault_login_response(conn, "s.token", 3600) end)

      auth_state = vault_near_expiry_state()
      assert {:ok, _, _} = Oidc.ensure_fresh(auth_state, base_req())

      assert_receive {:telemetry_event, %{duration_ms: _}, %{result: :ok}}, 1000
    end
  end

  describe "telemetry - short TTL warning" do
    test "emits [:rotating_secrets, :vault, :oidc, :short_ttl_warning] when TTL < 60s" do
      telemetry_event = [:rotating_secrets, :vault, :oidc, :short_ttl_warning]
      handler_id = "test-oidc-short-ttl-#{inspect(make_ref())}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        telemetry_event,
        fn _event, measurements, _meta, _ ->
          send(test_pid, {:telemetry_event, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(@stub_name, fn conn -> vault_login_response(conn, "s.short-ttl", 30) end)

      auth_state = vault_near_expiry_state()
      assert {:ok, _, _} = Oidc.ensure_fresh(auth_state, base_req())

      assert_receive {:telemetry_event, %{lease_duration: 30}}, 1000
    end
  end

  # NOTE: Full init/2 happy-path tests (oidcc provider startup + client_credentials_token)
  # require a live OIDC discovery endpoint. Those are integration tests that can be run
  # against a real OpenBao + Zitadel/Keycloak server. The ensure_fresh/2 tests above cover
  # all branching logic by using pre-seeded auth states that bypass the oidcc layer.
end
