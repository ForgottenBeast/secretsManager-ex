defmodule RotatingSecrets.Source.Vault.Auth.DispatcherTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Source.Vault.Auth.Dispatcher

  @stub_name :dispatcher_test_vault

  defp base_req, do: Req.new(plug: {Req.Test, @stub_name})

  # Pre-seeded JwtSvid auth state with a far-future expiry (no SPIRE call needed).
  defp fresh_jwt_svid_state do
    %{
      spiffe_ex: :test_spiffe,
      audience: "https://vault.example.com",
      role: "my-role",
      mount: "jwt",
      vault_token: "s.jwt-token",
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
  end

  # Pre-seeded Oidc auth state with a far-future expiry (no oidcc call needed).
  defp fresh_oidc_state do
    %{
      oidcc_provider: self(),
      client_id: "client",
      client_secret: "secret",
      role: "my-role",
      mount: "jwt",
      vault_token: "s.oidc-token",
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oidc_token: "oidc-bearer",
      oidc_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
  end

  describe "init/2" do
    test "nil auth returns {:ok, nil}" do
      assert {:ok, nil} = Dispatcher.init(nil, base_req())
    end
  end

  describe "ensure_fresh/2" do
    test "nil auth returns {:ok, req, nil}" do
      req = base_req()
      assert {:ok, ^req, nil} = Dispatcher.ensure_fresh(nil, req)
    end

    test "{:jwt_svid, state} with fresh token injects token and rewraps" do
      state = fresh_jwt_svid_state()
      assert {:ok, fresh_req, {:jwt_svid, new_state}} = Dispatcher.ensure_fresh({:jwt_svid, state}, base_req())
      assert new_state.vault_token == "s.jwt-token"
      assert Req.Request.get_header(fresh_req, "x-vault-token") == ["s.jwt-token"]
    end

    test "{:oidc, state} with fresh token injects token and rewraps" do
      state = fresh_oidc_state()
      assert {:ok, fresh_req, {:oidc, new_state}} = Dispatcher.ensure_fresh({:oidc, state}, base_req())
      assert new_state.vault_token == "s.oidc-token"
      assert Req.Request.get_header(fresh_req, "x-vault-token") == ["s.oidc-token"]
    end

    test "error from adapter is propagated unchanged" do
      # Use a near-expiry oidc state that will attempt vault re-auth and fail
      near_expiry_state = %{
        oidcc_provider: self(),
        client_id: "client",
        client_secret: "secret",
        role: "my-role",
        mount: "jwt",
        vault_token: "s.old-token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 10, :second),
        oidc_token: "oidc-bearer",
        oidc_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"auth" => %{"no_token" => "here"}})
      end)

      assert {:error, :vault_login_malformed_response} =
               Dispatcher.ensure_fresh({:oidc, near_expiry_state}, base_req())
    end
  end
end
