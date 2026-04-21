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

  describe "load/1 - first load sets lease_id and current_material in state" do
    test "state.lease_id and state.current_material are set after first successful load" do
      data = %{"pw" => "secret"}
      lease_opts = %{lease_id: "database/creds/my-role/xyz", lease_duration: 3600}
      Req.Test.stub(@stub_name, fn conn -> creds_response(conn, data, lease_opts) end)

      opts = stub_opts(key: "pw")
      {:ok, state} = Dynamic.init(opts)
      assert {:ok, "secret", _meta, new_state} = Dynamic.load(state)
      assert new_state.lease_id == "database/creds/my-role/xyz"
      assert new_state.current_material == "secret"
    end
  end

  describe "load/1 - meta.ttl_seconds" do
    test "ttl_seconds is set from body lease_duration" do
      data = %{"pw" => "x"}
      lease_opts = %{lease_id: "database/creds/my-role/abc", lease_duration: 7200}
      Req.Test.stub(@stub_name, fn conn -> creds_response(conn, data, lease_opts) end)

      opts = stub_opts(key: "pw")
      {:ok, state} = Dynamic.init(opts)
      assert {:ok, _, meta, _} = Dynamic.load(state)
      assert meta.ttl_seconds == 7200
    end
  end

  describe "load/1 - lease renewal" do
    defp renewal_response(conn, lease_id, new_duration) do
      Req.Test.json(conn, %{
        "lease_id" => lease_id,
        "lease_duration" => new_duration,
        "renewable" => true
      })
    end

    test "renewal succeeds: returns same material without new credential fetch" do
      lease_id = "database/creds/my-role/lease1"
      data = %{"pw" => "original"}
      lease_opts = %{lease_id: lease_id, lease_duration: 3600}

      # First call: GET creds; second call: PUT renew
      Req.Test.stub(@stub_name, fn conn ->
        case conn.request_path do
          "/v1/sys/leases/renew" -> renewal_response(conn, lease_id, 3600)
          _ -> creds_response(conn, data, lease_opts)
        end
      end)

      opts = stub_opts(key: "pw")
      {:ok, state} = Dynamic.init(opts)
      {:ok, _, _, state_with_lease} = Dynamic.load(state)

      assert state_with_lease.lease_id == lease_id

      # Second load: should renew, not fetch new creds
      assert {:ok, "original", renewal_meta, _} = Dynamic.load(state_with_lease)
      assert renewal_meta.lease_id == lease_id
      assert renewal_meta.ttl_seconds == 3600
    end

    test "renewal fails (403): falls back to GET creds" do
      lease_id = "database/creds/my-role/lease1"
      data = %{"pw" => "newcreds"}
      new_lease_opts = %{lease_id: "database/creds/my-role/lease2", lease_duration: 3600}

      Req.Test.stub(@stub_name, fn conn ->
        case conn.request_path do
          "/v1/sys/leases/renew" -> Plug.Conn.send_resp(conn, 403, "")
          _ -> creds_response(conn, data, new_lease_opts)
        end
      end)

      opts = stub_opts(key: "pw")
      {:ok, state} = Dynamic.init(opts)

      # Inject a lease_id to trigger the renewal path
      state_with_lease = %{state | lease_id: lease_id, current_material: "oldcreds"}

      assert {:ok, "newcreds", _meta, new_state} = Dynamic.load(state_with_lease)
      assert new_state.lease_id == "database/creds/my-role/lease2"
    end
  end

  describe "terminate/1" do
    test "calls PUT /v1/sys/leases/revoke when lease_id is present" do
      lease_id = "database/creds/my-role/to-revoke"
      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        if conn.request_path == "/v1/sys/leases/revoke" do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:revoke_called, body})
          Plug.Conn.send_resp(conn, 204, "")
        else
          Plug.Conn.send_resp(conn, 200, Jason.encode!(%{}))
        end
      end)

      opts = stub_opts()
      {:ok, state} = Dynamic.init(opts)
      state_with_lease = %{state | lease_id: lease_id}

      assert :ok = Dynamic.terminate(state_with_lease)
      assert_receive {:revoke_called, body}
      assert Jason.decode!(body)["lease_id"] == lease_id
    end

    test "returns :ok when lease_id is nil (no HTTP call)" do
      # stub would raise if called
      Req.Test.stub(@stub_name, fn _conn -> raise "should not be called" end)

      opts = stub_opts()
      {:ok, state} = Dynamic.init(opts)
      assert state.lease_id == nil
      assert :ok = Dynamic.terminate(state)
    end

    test "returns :ok when Vault is unreachable" do
      lease_id = "database/creds/my-role/lease1"

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      opts = stub_opts()
      {:ok, state} = Dynamic.init(opts)
      state_with_lease = %{state | lease_id: lease_id}

      assert :ok = Dynamic.terminate(state_with_lease)
    end
  end
end
