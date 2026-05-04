defmodule RotatingSecrets.Source.Vault.Transit.OperationsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Source.Vault.HTTP
  alias RotatingSecrets.Source.Vault.Transit.Operations

  @stub_name :operations_test

  defp base_req do
    HTTP.base_request(
      address: "http://127.0.0.1:8200",
      token: "s.token",
      req_options: [plug: {Req.Test, @stub_name}]
    )
  end

  describe "create_key/3" do
    test "204 response returns :ok" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert :ok = Operations.create_key(base_req(), "transit", "test-key")
    end

    test "400 (key exists) returns :ok — idempotent" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 400, ~s({"errors":["key already exists"]}))
      end)

      assert :ok = Operations.create_key(base_req(), "transit", "test-key")
    end

    test "403 returns {:error, :vault_auth_error}" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 403, "")
      end)

      assert {:error, :vault_auth_error} =
               Operations.create_key(base_req(), "transit", "test-key")
    end
  end

  describe "delete_key/3" do
    test "successful config + delete returns :ok" do
      call_count = :counters.new(1, [])

      Req.Test.stub(@stub_name, fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)
        # First call: POST config (200), second: DELETE key (204)
        if count == 1 do
          Req.Test.json(conn, %{})
        else
          Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert :ok = Operations.delete_key(base_req(), "transit", "test-key")
    end

    test "403 on config step returns {:error, :vault_auth_error}" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 403, "")
      end)

      assert {:error, :vault_auth_error} =
               Operations.delete_key(base_req(), "transit", "test-key")
    end
  end

  describe "encrypt/4" do
    test "returns ciphertext on success" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"data" => %{"ciphertext" => "vault:v1:abc123"}})
      end)

      assert {:ok, "vault:v1:abc123"} =
               Operations.encrypt(base_req(), "transit", "test-key", "plaintext")
    end

    test "returns error on auth failure" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 403, "")
      end)

      assert {:error, :vault_auth_error} =
               Operations.encrypt(base_req(), "transit", "test-key", "plaintext")
    end
  end

  describe "decrypt/4" do
    test "returns plaintext bytes on success" do
      pt = "hello world"
      pt_b64 = Base.encode64(pt)

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"data" => %{"plaintext" => pt_b64}})
      end)

      assert {:ok, ^pt} = Operations.decrypt(base_req(), "transit", "test-key", "vault:v1:abc123")
    end

    test "returns error on auth failure" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 403, "")
      end)

      assert {:error, :vault_auth_error} =
               Operations.decrypt(base_req(), "transit", "test-key", "vault:v1:abc123")
    end
  end

  describe "rotate_key/3" do
    test "returns {:ok, version} after rotation" do
      call_count = :counters.new(1, [])

      Req.Test.stub(@stub_name, fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          # First call: POST rotate (204)
          Plug.Conn.send_resp(conn, 204, "")
        else
          # Second call: GET metadata
          Req.Test.json(conn, %{
            "data" => %{
              "latest_version" => 2,
              "type" => "aes256-gcm96",
              "min_decryption_version" => 1
            }
          })
        end
      end)

      assert {:ok, 2} = Operations.rotate_key(base_req(), "transit", "test-key")
    end
  end

  describe "rewrap/4" do
    test "returns new ciphertext on success" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"data" => %{"ciphertext" => "vault:v2:xyz789"}})
      end)

      assert {:ok, "vault:v2:xyz789"} =
               Operations.rewrap(base_req(), "transit", "test-key", "vault:v1:abc123")
    end

    test "returns error on auth failure" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 403, "")
      end)

      assert {:error, :vault_auth_error} =
               Operations.rewrap(base_req(), "transit", "test-key", "vault:v1:abc123")
    end
  end
end
