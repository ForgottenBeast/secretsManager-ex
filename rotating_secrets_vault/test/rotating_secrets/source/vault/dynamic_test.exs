defmodule RotatingSecrets.Source.Vault.DynamicTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Source.Vault.Dynamic

  @stub_name :dynamic_test
  @valid_opts [
    address: "http://127.0.0.1:8200",
    mount: "database",
    path: "my-role",
    token: "s.token"
  ]

  defp stub_opts(extra \\ []) do
    @valid_opts
    |> Keyword.put(:req_options, [plug: {Req.Test, @stub_name}])
    |> Keyword.merge(extra)
  end

  defp creds_response(conn, data, opts \\ %{}) do
    lease_id = Map.get(opts, :lease_id, "")
    lease_duration = Map.get(opts, :lease_duration, 0)

    Req.Test.json(conn, %{
      "data" => data,
      "lease_id" => lease_id,
      "lease_duration" => lease_duration,
      "renewable" => lease_duration > 0
    })
  end

  describe "init/1" do
    test "ok with required opts" do
      assert {:ok, state} = Dynamic.init(@valid_opts)
      assert state.mount == "database"
      assert state.key == nil
    end

    test "ok with optional :key" do
      opts = Keyword.put(@valid_opts, :key, "username")
      assert {:ok, state} = Dynamic.init(opts)
      assert state.key == "username"
    end

    test "error for missing :address" do
      opts = Keyword.delete(@valid_opts, :address)
      assert {:error, {:invalid_option, :address}} = Dynamic.init(opts)
    end

    test "error for missing :token" do
      opts = Keyword.delete(@valid_opts, :token)
      assert {:error, {:invalid_option, :token}} = Dynamic.init(opts)
    end
  end

  describe "load/1 - material extraction" do
    test "extracts body[data][key] when :key given" do
      data = %{"username" => "db_user_abc", "password" => "pass123"}
      Req.Test.stub(@stub_name, fn conn -> creds_response(conn, data) end)

      opts = stub_opts(key: "username")
      {:ok, state} = Dynamic.init(opts)
      assert {:ok, "db_user_abc", _meta, _state} = Dynamic.load(state)
    end

    test "JSON-encodes body[data] when :key absent" do
      data = %{"username" => "user", "password" => "pass"}
      Req.Test.stub(@stub_name, fn conn -> creds_response(conn, data) end)

      opts = stub_opts()
      {:ok, state} = Dynamic.init(opts)
      assert {:ok, material, _meta, _state} = Dynamic.load(state)
      decoded = Jason.decode!(material)
      assert decoded["username"] == "user"
      assert decoded["password"] == "pass"
    end
  end

  describe "load/1 - meta" do
    test "version is nil" do
      Req.Test.stub(@stub_name, fn conn -> creds_response(conn, %{"pw" => "x"}) end)

      opts = stub_opts(key: "pw")
      {:ok, state} = Dynamic.init(opts)
      assert {:ok, _, meta, _} = Dynamic.load(state)
      assert meta.version == nil
    end

    test "lease_id and lease_duration_ms present when lease_duration > 0" do
      data = %{"pw" => "x"}
      lease_opts = %{lease_id: "database/creds/my-role/abc123", lease_duration: 3600}
      Req.Test.stub(@stub_name, fn conn -> creds_response(conn, data, lease_opts) end)

      opts = stub_opts(key: "pw")
      {:ok, state} = Dynamic.init(opts)
      assert {:ok, _, meta, _} = Dynamic.load(state)
      assert meta.lease_id == "database/creds/my-role/abc123"
      assert meta.lease_duration_ms == 3_600_000
    end

    test "lease fields absent when lease_duration is 0" do
      Req.Test.stub(@stub_name, fn conn -> creds_response(conn, %{"pw" => "x"}) end)

      opts = stub_opts(key: "pw")
      {:ok, state} = Dynamic.init(opts)
      assert {:ok, _, meta, _} = Dynamic.load(state)
      refute Map.has_key?(meta, :lease_duration_ms)
    end
  end

  describe "load/1 - HTTP errors" do
    test "403 returns :vault_auth_error" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)
      opts = stub_opts()
      {:ok, state} = Dynamic.init(opts)
      assert {:error, :vault_auth_error, _} = Dynamic.load(state)
    end

    test "503 returns :vault_server_error" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
      opts = stub_opts()
      {:ok, state} = Dynamic.init(opts)
      assert {:error, :vault_server_error, _} = Dynamic.load(state)
    end
  end
end
