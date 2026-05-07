defmodule RotatingSecrets.Source.Vault.Auth.ZitadelPrivateKeyJwtTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Source.Vault.Auth.ZitadelPrivateKeyJwt

  @openbao_stub :zitadel_pkjwt_test_openbao
  @zitadel_stub :zitadel_pkjwt_test_zitadel

  # Path must match the one passed in opts below.
  @key_kv_path "secret/data/test/zitadel-key"

  setup_all do
    # Generate a 2048-bit RSA key once for the whole suite.
    rsa_key = :public_key.generate_key({:rsa, 2048, 65537})
    der = :public_key.der_encode(:RSAPrivateKey, rsa_key)
    pem = :public_key.pem_encode([{:RSAPrivateKey, der, :not_encrypted}])

    key_json =
      Jason.encode!(%{
        "type" => "serviceaccount",
        "keyId" => "test-key-id-001",
        "key" => pem,
        "userId" => "test-user-id-001"
      })

    {:ok, key_json: key_json}
  end

  defp base_req(stub_name), do: Req.new(plug: {Req.Test, stub_name})

  defp opts(extra \\ []) do
    [
      zitadel_url: "https://zitadel.test",
      key_kv_path: @key_kv_path,
      vault_role: "test-role",
      vault_mount: "jwt",
      zitadel_req_opts: [plug: {Req.Test, @zitadel_stub}]
    ] ++ extra
  end

  # Stub helpers — called inside Req.Test.stub/2 fns.

  defp kv_ok(conn, key_json) do
    Req.Test.json(conn, %{
      "data" => %{
        "data" => %{"key_json" => key_json}
      }
    })
  end

  defp kv_not_found(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(404, Jason.encode!(%{"errors" => ["not found"]}))
  end

  defp kv_malformed(conn) do
    Req.Test.json(conn, %{"data" => %{"data" => %{"unexpected_field" => "oops"}}})
  end

  defp zitadel_ok(conn), do: Req.Test.json(conn, %{"access_token" => "zitadel-access-token"})

  defp zitadel_error(conn, status) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(%{"error" => "invalid_client"}))
  end

  defp vault_login_ok(conn, token \\ "s.test-vault-token", ttl \\ 3600) do
    Req.Test.json(conn, %{"auth" => %{"client_token" => token, "lease_duration" => ttl}})
  end

  defp vault_login_malformed(conn) do
    Req.Test.json(conn, %{"auth" => %{"no_token" => "here"}})
  end

  defp stub_openbao_happy(key_json) do
    Req.Test.stub(@openbao_stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v1/" <> @key_kv_path} -> kv_ok(conn, key_json)
        {"POST", "/v1/auth/jwt/login"} -> vault_login_ok(conn)
        _ -> Plug.Conn.send_resp(conn, 500, "unexpected request")
      end
    end)
  end

  # ── init/2 — happy path ───────────────────────────────────────────────────────

  describe "init/2 — happy path" do
    test "returns auth_state with vault_token and token_expires_at populated", %{
      key_json: key_json
    } do
      stub_openbao_happy(key_json)
      Req.Test.stub(@zitadel_stub, &zitadel_ok/1)

      assert {:ok, auth_state} = ZitadelPrivateKeyJwt.init(opts(), base_req(@openbao_stub))

      assert auth_state.vault_token == "s.test-vault-token"
      assert %DateTime{} = auth_state.token_expires_at
      assert auth_state.parsed_key.user_id == "test-user-id-001"
      assert auth_state.parsed_key.key_id == "test-key-id-001"
    end
  end

  # ── init/2 — KV error paths ───────────────────────────────────────────────────

  describe "init/2 — KV not found" do
    test "returns {:error, {:zitadel_key_not_found, path}}", %{key_json: _} do
      Req.Test.stub(@openbao_stub, fn conn ->
        case conn.request_path do
          "/v1/" <> @key_kv_path -> kv_not_found(conn)
          _ -> Plug.Conn.send_resp(conn, 500, "unexpected")
        end
      end)

      assert {:error, {:zitadel_key_not_found, @key_kv_path}} =
               ZitadelPrivateKeyJwt.init(opts(), base_req(@openbao_stub))
    end
  end

  describe "init/2 — malformed KV response" do
    test "returns {:error, :zitadel_key_malformed_kv_response}", %{key_json: _} do
      Req.Test.stub(@openbao_stub, fn conn -> kv_malformed(conn) end)

      assert {:error, :zitadel_key_malformed_kv_response} =
               ZitadelPrivateKeyJwt.init(opts(), base_req(@openbao_stub))
    end
  end

  describe "init/2 — invalid PEM in key_json" do
    test "returns {:error, :zitadel_key_invalid_pem}", %{key_json: _} do
      bad_key_json =
        Jason.encode!(%{
          "type" => "serviceaccount",
          "keyId" => "k1",
          "key" => "not-a-pem",
          "userId" => "u1"
        })

      Req.Test.stub(@openbao_stub, fn conn -> kv_ok(conn, bad_key_json) end)

      assert {:error, :zitadel_key_invalid_pem} =
               ZitadelPrivateKeyJwt.init(opts(), base_req(@openbao_stub))
    end
  end

  describe "init/2 — key_json missing required fields" do
    test "returns {:error, :zitadel_key_missing_fields}", %{key_json: _} do
      bad_key_json = Jason.encode!(%{"type" => "serviceaccount"})
      Req.Test.stub(@openbao_stub, fn conn -> kv_ok(conn, bad_key_json) end)

      assert {:error, :zitadel_key_missing_fields} =
               ZitadelPrivateKeyJwt.init(opts(), base_req(@openbao_stub))
    end
  end

  # ── init/2 — Zitadel error paths ─────────────────────────────────────────────

  describe "init/2 — Zitadel 4xx" do
    test "returns {:error, {:zitadel_jwt_bearer_failed, status, body}}", %{key_json: key_json} do
      Req.Test.stub(@openbao_stub, fn conn -> kv_ok(conn, key_json) end)
      Req.Test.stub(@zitadel_stub, &zitadel_error(&1, 401))

      assert {:error, {:zitadel_jwt_bearer_failed, 401, _body}} =
               ZitadelPrivateKeyJwt.init(opts(), base_req(@openbao_stub))
    end
  end

  # ── init/2 — OpenBao login error paths ───────────────────────────────────────

  describe "init/2 — OpenBao login malformed response" do
    test "returns {:error, :openbao_login_malformed_response}", %{key_json: key_json} do
      Req.Test.stub(@openbao_stub, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v1/" <> @key_kv_path} -> kv_ok(conn, key_json)
          {"POST", "/v1/auth/jwt/login"} -> vault_login_malformed(conn)
          _ -> Plug.Conn.send_resp(conn, 500, "unexpected")
        end
      end)

      Req.Test.stub(@zitadel_stub, &zitadel_ok/1)

      assert {:error, :openbao_login_malformed_response} =
               ZitadelPrivateKeyJwt.init(opts(), base_req(@openbao_stub))
    end
  end

  # ── ensure_fresh/2 ────────────────────────────────────────────────────────────

  describe "ensure_fresh/2 — token not near expiry" do
    test "injects token without re-login", %{key_json: key_json} do
      stub_openbao_happy(key_json)
      Req.Test.stub(@zitadel_stub, &zitadel_ok/1)

      {:ok, auth_state} = ZitadelPrivateKeyJwt.init(opts(), base_req(@openbao_stub))

      assert {:ok, fresh_req, new_auth} =
               ZitadelPrivateKeyJwt.ensure_fresh(auth_state, base_req(@openbao_stub))

      assert new_auth.vault_token == "s.test-vault-token"
      assert Req.Request.get_header(fresh_req, "x-vault-token") == ["s.test-vault-token"]
    end
  end

  describe "ensure_fresh/2 — token near expiry" do
    test "re-runs Zitadel exchange and returns updated token", %{key_json: key_json} do
      stub_openbao_happy(key_json)
      Req.Test.stub(@zitadel_stub, &zitadel_ok/1)

      {:ok, auth_state} = ZitadelPrivateKeyJwt.init(opts(), base_req(@openbao_stub))

      near_expiry = %{auth_state | token_expires_at: DateTime.add(DateTime.utc_now(), 10, :second)}

      Req.Test.stub(@openbao_stub, fn conn -> vault_login_ok(conn, "s.refreshed-token", 3600) end)
      Req.Test.stub(@zitadel_stub, &zitadel_ok/1)

      assert {:ok, fresh_req, new_auth} =
               ZitadelPrivateKeyJwt.ensure_fresh(near_expiry, base_req(@openbao_stub))

      assert new_auth.vault_token == "s.refreshed-token"
      assert Req.Request.get_header(fresh_req, "x-vault-token") == ["s.refreshed-token"]
    end
  end

  # ── short TTL warning telemetry ───────────────────────────────────────────────

  describe "short TTL warning telemetry" do
    test "emits short_ttl_warning when vault TTL < 60s", %{key_json: key_json} do
      event = [:rotating_secrets, :vault, :zitadel_private_key_jwt, :short_ttl_warning]
      handler_id = "test-short-ttl-#{inspect(make_ref())}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        event,
        fn _event, measurements, _meta, _ ->
          send(test_pid, {:telemetry_event, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(@openbao_stub, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v1/" <> @key_kv_path} -> kv_ok(conn, key_json)
          {"POST", "/v1/auth/jwt/login"} -> vault_login_ok(conn, "s.short-ttl-token", 30)
          _ -> Plug.Conn.send_resp(conn, 500, "unexpected")
        end
      end)

      Req.Test.stub(@zitadel_stub, &zitadel_ok/1)

      assert {:ok, _auth_state} = ZitadelPrivateKeyJwt.init(opts(), base_req(@openbao_stub))
      assert_receive {:telemetry_event, %{lease_duration: 30}}, 2000
    end
  end

  # ── invalid options ───────────────────────────────────────────────────────────

  describe "init/2 — missing required opts" do
    test "returns error when zitadel_url is missing", %{key_json: _} do
      bad_opts = opts() |> Keyword.delete(:zitadel_url)
      assert {:error, {:invalid_option, :zitadel_url}} = ZitadelPrivateKeyJwt.init(bad_opts, base_req(@openbao_stub))
    end

    test "returns error when vault_role is missing", %{key_json: _} do
      bad_opts = opts() |> Keyword.delete(:vault_role)
      assert {:error, {:invalid_option, :vault_role}} = ZitadelPrivateKeyJwt.init(bad_opts, base_req(@openbao_stub))
    end
  end
end
