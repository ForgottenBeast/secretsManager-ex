defmodule RotatingSecrets.Source.Vault.KvV1Test do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Source.Vault.KvV1

  @stub_name :kv_v1_test
  @valid_opts [
    address: "http://127.0.0.1:8200",
    mount: "secret",
    path: "myapp/db",
    token: "s.token",
    key: "password"
  ]

  defp stub_opts(extra \\ []) do
    @valid_opts
    |> Keyword.put(:req_options, plug: {Req.Test, @stub_name})
    |> Keyword.merge(extra)
  end

  defp kv_response(conn, key, value) do
    Req.Test.json(conn, %{"data" => %{key => value}})
  end

  describe "init/1" do
    test "ok with all required opts" do
      assert {:ok, state} = KvV1.init(@valid_opts)
      assert state.key == "password"
    end

    test "error for missing :key" do
      opts = Keyword.delete(@valid_opts, :key)
      assert {:error, {:invalid_option, :key}} = KvV1.init(opts)
    end

    test "error for missing :address" do
      opts = Keyword.delete(@valid_opts, :address)
      assert {:error, {:invalid_option, :address}} = KvV1.init(opts)
    end

    test "error for missing :token" do
      opts = Keyword.delete(@valid_opts, :token)
      assert {:error, {:invalid_option, :token}} = KvV1.init(opts)
    end
  end

  describe "init/1 input validation" do
    test "rejects path-traversal mount" do
      opts = Keyword.put(@valid_opts, :mount, "../sys")
      assert {:error, {:invalid_option, :mount}} = KvV1.init(opts)
    end

    test "rejects null-byte in mount" do
      opts = Keyword.put(@valid_opts, :mount, "a\0b")
      assert {:error, {:invalid_option, :mount}} = KvV1.init(opts)
    end

    test "accepts mount with dots" do
      opts = Keyword.put(@valid_opts, :mount, "my.app")
      assert {:ok, _state} = KvV1.init(opts)
    end

    test "rejects CRLF injection in namespace" do
      opts = Keyword.put(@valid_opts, :namespace, "ns\r\nX-Evil: h")
      assert {:error, {:invalid_option, :namespace}} = KvV1.init(opts)
    end

    test "rejects path-traversal in path" do
      opts = Keyword.put(@valid_opts, :path, "../../../etc/passwd")
      assert {:error, {:invalid_option, :path}} = KvV1.init(opts)
    end

    test "accepts nested path" do
      opts = Keyword.put(@valid_opts, :path, "secret/data/nested")
      assert {:ok, _state} = KvV1.init(opts)
    end
  end

  describe "load/1 - happy path" do
    test "extracts body[data][key] as material, version is nil" do
      Req.Test.stub(@stub_name, fn conn -> kv_response(conn, "password", "s3cret") end)

      opts = stub_opts()
      {:ok, state} = KvV1.init(opts)
      assert {:ok, "s3cret", meta, _state} = KvV1.load(state)
      assert meta.version == nil
    end

    test "content_hash is lowercase hex SHA-256 of material" do
      Req.Test.stub(@stub_name, fn conn -> kv_response(conn, "password", "s3cret") end)

      opts = stub_opts()
      {:ok, state} = KvV1.init(opts)
      assert {:ok, "s3cret", meta, _state} = KvV1.load(state)
      hash = :crypto.hash(:sha256, "s3cret")
      expected = Base.encode16(hash, case: :lower)
      assert meta.content_hash == expected
    end

    test "same-value re-issue produces same content_hash" do
      Req.Test.stub(@stub_name, fn conn -> kv_response(conn, "password", "stable") end)

      opts = stub_opts()
      {:ok, state} = KvV1.init(opts)
      {:ok, _, meta1, state2} = KvV1.load(state)
      {:ok, _, meta2, _state3} = KvV1.load(state2)
      assert meta1.content_hash == meta2.content_hash
    end

    test "different values produce different content_hash" do
      Req.Test.stub(:kv_v1_val_a, fn conn -> kv_response(conn, "password", "value-a") end)
      Req.Test.stub(:kv_v1_val_b, fn conn -> kv_response(conn, "password", "value-b") end)

      opts_a = Keyword.put(@valid_opts, :req_options, plug: {Req.Test, :kv_v1_val_a})
      opts_b = Keyword.put(@valid_opts, :req_options, plug: {Req.Test, :kv_v1_val_b})

      {:ok, state_a} = KvV1.init(opts_a)
      {:ok, state_b} = KvV1.init(opts_b)
      {:ok, _, meta_a, _} = KvV1.load(state_a)
      {:ok, _, meta_b, _} = KvV1.load(state_b)
      assert meta_a.content_hash != meta_b.content_hash
    end
  end

  describe "load/1 - HTTP errors" do
    test "403 returns :vault_auth_error" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)
      opts = stub_opts()
      {:ok, state} = KvV1.init(opts)
      assert {:error, :vault_auth_error, _} = KvV1.load(state)
    end

    test "404 returns :vault_secret_not_found" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      opts = stub_opts()
      {:ok, state} = KvV1.init(opts)
      assert {:error, :vault_secret_not_found, _} = KvV1.load(state)
    end

    test "503 returns :vault_server_error" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
      opts = stub_opts()
      {:ok, state} = KvV1.init(opts)
      assert {:error, :vault_server_error, _} = KvV1.load(state)
    end
  end
end
