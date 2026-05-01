defmodule RotatingSecrets.Source.Vault.Auth.ZitadelOidcTest do
  @moduledoc false

  # async: false since SpiffeEx.Registry is a global named process
  use ExUnit.Case, async: false

  alias RotatingSecrets.Source.Vault.Auth.ZitadelOidc

  @stub_name :zitadel_oidc_test_vault

  defp fake_token(access_token \\ "fake-zitadel-access-token") do
    %SpiffeEx.Token{
      access_token: access_token,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
  end

  defp ok_authenticate_fn(token \\ fake_token()) do
    fn _name -> {:ok, token} end
  end

  defp error_authenticate_fn do
    fn _name -> {:error, :workload_api_unavailable} end
  end

  defp base_req(stub_name) do
    Req.new(plug: {Req.Test, stub_name})
  end

  defp vault_login_response(conn, token \\ "s.vault-test-token", ttl \\ 3600) do
    Req.Test.json(conn, %{
      "auth" => %{
        "client_token" => token,
        "lease_duration" => ttl
      }
    })
  end

  describe "init/2 happy path" do
    test "returns auth_state with vault_token populated" do
      Req.Test.stub(@stub_name, fn conn -> vault_login_response(conn) end)

      opts = [
        spiffe_ex: :my_spiffe,
        role: "my-role",
        authenticate_fn: ok_authenticate_fn()
      ]

      base = base_req(@stub_name)

      assert {:ok, auth_state} = ZitadelOidc.init(opts, base)
      assert auth_state.vault_token == "s.vault-test-token"
      assert %DateTime{} = auth_state.token_expires_at
    end
  end

  describe "init/2 - SpiffeEx.authenticate fails" do
    test "returns {:error, :spiffe_agent_unavailable}" do
      opts = [
        spiffe_ex: :my_spiffe,
        role: "my-role",
        authenticate_fn: error_authenticate_fn()
      ]

      base = base_req(@stub_name)

      assert {:error, :spiffe_agent_unavailable} = ZitadelOidc.init(opts, base)
    end
  end

  describe "init/2 - malformed vault response" do
    test "returns {:error, :vault_login_malformed_response}" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"auth" => %{"no_token" => "here"}})
      end)

      opts = [
        spiffe_ex: :my_spiffe,
        role: "my-role",
        authenticate_fn: ok_authenticate_fn()
      ]

      base = base_req(@stub_name)

      assert {:error, :vault_login_malformed_response} = ZitadelOidc.init(opts, base)
    end
  end

  describe "init/2 - missing :spiffe_ex opt" do
    test "returns {:error, {:invalid_option, :spiffe_ex}}" do
      opts = [role: "my-role"]
      base = base_req(@stub_name)

      assert {:error, {:invalid_option, :spiffe_ex}} = ZitadelOidc.init(opts, base)
    end
  end

  describe "init/2 - missing :role opt" do
    test "returns {:error, {:invalid_option, :role}}" do
      opts = [spiffe_ex: :my_spiffe]
      base = base_req(@stub_name)

      assert {:error, {:invalid_option, :role}} = ZitadelOidc.init(opts, base)
    end
  end

  describe "ensure_fresh/2 - token not near expiry" do
    test "injects token without re-login" do
      Req.Test.stub(@stub_name, fn conn -> vault_login_response(conn, "s.fresh-token", 3600) end)

      opts = [
        spiffe_ex: :my_spiffe,
        role: "my-role",
        authenticate_fn: ok_authenticate_fn()
      ]

      base = base_req(@stub_name)

      {:ok, auth_state} = ZitadelOidc.init(opts, base)
      assert auth_state.vault_token == "s.fresh-token"

      assert {:ok, fresh_req, new_auth} = ZitadelOidc.ensure_fresh(auth_state, base)
      assert new_auth.vault_token == "s.fresh-token"
      vault_token_headers = Req.Request.get_header(fresh_req, "x-vault-token")
      assert vault_token_headers == ["s.fresh-token"]
    end
  end

  describe "ensure_fresh/2 - token near expiry" do
    test "re-authenticates and returns updated auth_state" do
      Req.Test.stub(@stub_name, fn conn -> vault_login_response(conn, "s.initial-token", 3600) end)

      opts = [
        spiffe_ex: :my_spiffe,
        role: "my-role",
        authenticate_fn: ok_authenticate_fn()
      ]

      base = base_req(@stub_name)

      {:ok, auth_state} = ZitadelOidc.init(opts, base)

      # Force token to be near expiry (<=30s remaining)
      near_expiry_auth = %{auth_state | token_expires_at: DateTime.add(DateTime.utc_now(), 10, :second)}

      Req.Test.stub(@stub_name, fn conn -> vault_login_response(conn, "s.new-token", 3600) end)

      assert {:ok, _fresh_req, new_auth} = ZitadelOidc.ensure_fresh(near_expiry_auth, base)
      assert new_auth.vault_token == "s.new-token"
    end
  end

  describe "telemetry - login event" do
    test "emits [:rotating_secrets, :vault, :zitadel_oidc, :login] on successful login" do
      telemetry_event = [:rotating_secrets, :vault, :zitadel_oidc, :login]
      handler_id = "test-login-#{inspect(make_ref())}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        telemetry_event,
        fn _event, measurements, meta, _ ->
          send(test_pid, {:telemetry_event, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(@stub_name, fn conn -> vault_login_response(conn) end)

      opts = [
        spiffe_ex: :my_spiffe,
        role: "my-role",
        authenticate_fn: ok_authenticate_fn()
      ]

      base = base_req(@stub_name)

      assert {:ok, _auth_state} = ZitadelOidc.init(opts, base)
      assert_receive {:telemetry_event, %{duration_ms: _}, %{result: :ok}}, 1000
    end
  end

  describe "telemetry - short_ttl_warning event" do
    test "emits [:rotating_secrets, :vault, :zitadel_oidc, :short_ttl_warning] when TTL < 60s" do
      telemetry_event = [:rotating_secrets, :vault, :zitadel_oidc, :short_ttl_warning]
      handler_id = "test-short-ttl-#{inspect(make_ref())}"
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

      Req.Test.stub(@stub_name, fn conn -> vault_login_response(conn, "s.short-ttl-token", 30) end)

      opts = [
        spiffe_ex: :my_spiffe,
        role: "my-role",
        authenticate_fn: ok_authenticate_fn()
      ]

      base = base_req(@stub_name)

      assert {:ok, _auth_state} = ZitadelOidc.init(opts, base)
      assert_receive {:telemetry_event, %{lease_duration: 30}}, 1000
    end
  end
end
