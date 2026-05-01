defmodule RotatingSecrets.Source.Vault.Auth.JwtSvidTest do
  @moduledoc false

  # async: false since SpiffeEx.Registry is a global named process
  use ExUnit.Case, async: false

  alias RotatingSecrets.Source.Vault.Auth.JwtSvid

  @stub_name :jwt_svid_test_vault
  @spiffe_name :jwt_svid_test_spiffe_ex

  # A fake WorkloadAPI that returns a hardcoded SVID
  defmodule FakeWorkloadAPI do
    @behaviour SpiffeEx.WorkloadAPI

    @impl true
    def fetch_jwt_svid(_endpoint, _audience, _grpc_opts) do
      svid = %SpiffeEx.SVID{
        token: "fake-jwt-svid-token",
        spiffe_id: "spiffe://test/workload",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      {:ok, svid}
    end
  end

  # A fake WorkloadAPI that always returns unavailable
  defmodule UnavailableWorkloadAPI do
    @behaviour SpiffeEx.WorkloadAPI

    @impl true
    def fetch_jwt_svid(_endpoint, _audience, _grpc_opts) do
      {:error, :workload_api_unavailable}
    end
  end

  setup_all do
    # Start a single SpiffeEx supervisor shared across all tests.
    # SpiffeEx.Registry is a global named process, so we can only start it once.
    # start_supervised! ensures ExUnit manages the lifecycle via its supervision tree.
    start_supervised!({SpiffeEx, [name: @spiffe_name, endpoint: "unix:/fake/spire.sock", workload_api_mod: FakeWorkloadAPI]})
    :ok
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

      opts = [spiffe_ex: @spiffe_name, audience: "https://vault.example.com", role: "my-role"]
      base = base_req(@stub_name)

      assert {:ok, auth_state} = JwtSvid.init(opts, base)
      assert auth_state.vault_token == "s.vault-test-token"
      assert %DateTime{} = auth_state.token_expires_at
    end
  end

  describe "init/2 - SPIRE agent unavailable" do
    test "returns {:error, :spiffe_agent_unavailable}" do
      # Start a separate SpiffeEx supervisor with UnavailableWorkloadAPI.
      # We cannot start another global SpiffeEx.Registry, so we start the SvidCache
      # directly and use a unique name.
      unavail_name = :"unavail_spiffe_#{:erlang.unique_integer([:positive])}"

      {:ok, _cache_pid} =
        SpiffeEx.SvidCache.start_link([
          {:name, unavail_name},
          {:endpoint, "unix:/fake/spire.sock"},
          {:workload_api_mod, UnavailableWorkloadAPI}
        ])

      opts = [spiffe_ex: unavail_name, audience: "https://vault.example.com", role: "my-role"]
      base = base_req(@stub_name)

      assert {:error, :spiffe_agent_unavailable} = JwtSvid.init(opts, base)
    end
  end

  describe "init/2 - malformed vault response" do
    test "returns {:error, :vault_login_malformed_response}" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"auth" => %{"no_token" => "here"}})
      end)

      opts = [spiffe_ex: @spiffe_name, audience: "https://vault.example.com", role: "my-role"]
      base = base_req(@stub_name)

      assert {:error, :vault_login_malformed_response} = JwtSvid.init(opts, base)
    end
  end

  describe "ensure_fresh/2 - token not near expiry" do
    test "injects token without re-login" do
      Req.Test.stub(@stub_name, fn conn -> vault_login_response(conn, "s.fresh-token", 3600) end)

      opts = [spiffe_ex: @spiffe_name, audience: "https://vault.example.com", role: "my-role"]
      base = base_req(@stub_name)

      {:ok, auth_state} = JwtSvid.init(opts, base)
      assert auth_state.vault_token == "s.fresh-token"

      assert {:ok, fresh_req, new_auth} = JwtSvid.ensure_fresh(auth_state, base)
      assert new_auth.vault_token == "s.fresh-token"
      vault_token_headers = Req.Request.get_header(fresh_req, "x-vault-token")
      assert vault_token_headers == ["s.fresh-token"]
    end
  end

  describe "ensure_fresh/2 - token near expiry" do
    test "re-logins and returns updated auth_state" do
      Req.Test.stub(@stub_name, fn conn -> vault_login_response(conn, "s.initial-token", 3600) end)

      opts = [spiffe_ex: @spiffe_name, audience: "https://vault.example.com", role: "my-role"]
      base = base_req(@stub_name)

      {:ok, auth_state} = JwtSvid.init(opts, base)

      # Force token to be near expiry (<=30s remaining)
      near_expiry_auth = %{auth_state | token_expires_at: DateTime.add(DateTime.utc_now(), 10, :second)}

      Req.Test.stub(@stub_name, fn conn -> vault_login_response(conn, "s.new-token", 3600) end)

      assert {:ok, _fresh_req, new_auth} = JwtSvid.ensure_fresh(near_expiry_auth, base)
      assert new_auth.vault_token == "s.new-token"
    end
  end

  describe "short TTL warning telemetry" do
    test "emits short_ttl_warning event when TTL < 60s" do
      telemetry_event = [:rotating_secrets, :vault, :jwt_svid, :short_ttl_warning]
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

      opts = [spiffe_ex: @spiffe_name, audience: "https://vault.example.com", role: "my-role"]
      base = base_req(@stub_name)

      assert {:ok, _auth_state} = JwtSvid.init(opts, base)
      assert_receive {:telemetry_event, %{lease_duration: 30}}, 1000
    end
  end
end
