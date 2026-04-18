defmodule RotatingSecrets.Source.Vault.KvV2Test do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Source.Vault.KvV2

  @stub_name :kv_v2_test
  @valid_opts [
    address: "http://127.0.0.1:8200",
    mount: "secret",
    path: "myapp/db",
    token: "s.sekret-token"
  ]

  defp stub_opts(extra \\ []) do
    @valid_opts
    |> Keyword.put(:req_options, [plug: {Req.Test, @stub_name}])
    |> Keyword.merge(extra)
  end

  defp happy_response(conn, material \\ "my-secret", version \\ 1) do
    Req.Test.json(conn, %{
      "data" => %{
        "data" => material,
        "metadata" => %{"version" => version}
      }
    })
  end

  describe "init/1" do
    test "returns {:ok, state} with valid opts" do
      assert {:ok, state} = KvV2.init(@valid_opts)
      assert state.address == "http://127.0.0.1:8200"
      assert state.mount == "secret"
      assert state.path == "myapp/db"
    end

    test "error for missing :address" do
      opts = Keyword.delete(@valid_opts, :address)
      assert {:error, {:invalid_option, :address}} = KvV2.init(opts)
    end

    test "error for missing :mount" do
      opts = Keyword.delete(@valid_opts, :mount)
      assert {:error, {:invalid_option, :mount}} = KvV2.init(opts)
    end

    test "error for missing :path" do
      opts = Keyword.delete(@valid_opts, :path)
      assert {:error, {:invalid_option, :path}} = KvV2.init(opts)
    end

    test "error for missing :token" do
      opts = Keyword.delete(@valid_opts, :token)
      assert {:error, {:invalid_option, :token}} = KvV2.init(opts)
    end

    test "error tuple does not contain token value" do
      opts = Keyword.delete(@valid_opts, :address)
      {:error, reason} = KvV2.init(opts)
      reason_str = inspect(reason)
      refute reason_str =~ "s.sekret-token"
    end

    test "accepts valid :namespace" do
      opts = Keyword.put(@valid_opts, :namespace, "my-ns")
      assert {:ok, state} = KvV2.init(opts)
      assert state.namespace == "my-ns"
    end

    test "rejects empty string :namespace" do
      opts = Keyword.put(@valid_opts, :namespace, "")
      assert {:error, {:invalid_option, :namespace}} = KvV2.init(opts)
    end

    test "rejects non-binary :namespace" do
      opts = Keyword.put(@valid_opts, :namespace, :bad)
      assert {:error, {:invalid_option, :namespace}} = KvV2.init(opts)
    end
  end

  describe "load/1 - happy path" do
    test "extracts material and version from KV v2 body" do
      Req.Test.stub(@stub_name, fn conn -> happy_response(conn, "db-password", 5) end)

      opts = stub_opts()
      {:ok, state} = KvV2.init(opts)
      assert {:ok, "db-password", meta, _state} = KvV2.load(state)
      assert meta.version == 5
    end

    test "content_hash is lowercase hex SHA-256 of material" do
      Req.Test.stub(@stub_name, fn conn -> happy_response(conn, "abc") end)

      opts = stub_opts()
      {:ok, state} = KvV2.init(opts)
      assert {:ok, "abc", meta, _state} = KvV2.load(state)
      hash = :crypto.hash(:sha256, "abc")
      expected = Base.encode16(hash, case: :lower)
      assert meta.content_hash == expected
    end
  end

  describe "load/1 - HTTP errors" do
    test "403 returns :vault_auth_error" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)
      opts = stub_opts()
      {:ok, state} = KvV2.init(opts)
      assert {:error, :vault_auth_error, _} = KvV2.load(state)
    end

    test "404 returns :vault_secret_not_found" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      opts = stub_opts()
      {:ok, state} = KvV2.init(opts)
      assert {:error, :vault_secret_not_found, _} = KvV2.load(state)
    end

    test "429 returns :vault_rate_limited" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 429, "") end)
      opts = stub_opts()
      {:ok, state} = KvV2.init(opts)
      assert {:error, :vault_rate_limited, _} = KvV2.load(state)
    end

    test "503 returns :vault_server_error" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
      opts = stub_opts()
      {:ok, state} = KvV2.init(opts)
      assert {:error, :vault_server_error, _} = KvV2.load(state)
    end
  end

  describe "load/1 - namespace header" do
    test "X-Vault-Namespace header injected when :namespace present" do
      Req.Test.stub(@stub_name, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-vault-namespace") == ["corp/team"]
        happy_response(conn)
      end)

      opts = stub_opts(namespace: "corp/team")
      {:ok, state} = KvV2.init(opts)
      assert {:ok, _, _, _} = KvV2.load(state)
    end

    test "X-Vault-Namespace header absent when :namespace not given" do
      Req.Test.stub(@stub_name, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-vault-namespace") == []
        happy_response(conn)
      end)

      opts = stub_opts()
      {:ok, state} = KvV2.init(opts)
      assert {:ok, _, _, _} = KvV2.load(state)
    end
  end

  describe "non-load callbacks" do
    test "subscribe_changes/1 returns :not_supported" do
      {:ok, state} = KvV2.init(@valid_opts)
      assert :not_supported = KvV2.subscribe_changes(state)
    end

    test "handle_change_notification/2 returns :ignored" do
      {:ok, state} = KvV2.init(@valid_opts)
      assert :ignored = KvV2.handle_change_notification(:any_msg, state)
    end

    test "terminate/1 returns :ok" do
      {:ok, state} = KvV2.init(@valid_opts)
      assert :ok = KvV2.terminate(state)
    end
  end
end
