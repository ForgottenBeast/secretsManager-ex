defmodule RotatingSecretsVault.Integration.DynamicPgTest do
  @moduledoc false

  use ExUnit.Case, async: false

  # Requires both OpenBao (for credential issuance) and PostgreSQL (for login
  # verification). Both are started by scripts/run_db_tests.sh.
  @moduletag :openbao_db

  alias RotatingSecrets.Secret

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup_all do
    OpenBaoHelper.setup_database_engine!(OpenBaoHelper.pg_connection_url())
    PgFixtures.setup!()

    on_exit(fn ->
      PgFixtures.teardown!()
      OpenBaoHelper.teardown_database_engine!()
    end)

    :ok
  end

  setup do
    name = :"dynamic_pg_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> RotatingSecrets.deregister(name) end)
    {:ok, name: name}
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  test "dynamic credentials authenticate to PostgreSQL", %{name: name} do
    {:ok, _} = register(name)

    %{"username" => user, "password" => pass} = current_creds(name)

    assert {:ok, conn} = pg_connect(user, pass)
    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)
  end

  test "dynamic credentials can read all fixture rows", %{name: name} do
    {:ok, _} = register(name)

    %{"username" => user, "password" => pass} = current_creds(name)

    {:ok, conn} = pg_connect(user, pass)
    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)

    result = Postgrex.query!(
      conn,
      "SELECT id, name, value FROM #{PgFixtures.table()} ORDER BY id",
      []
    )

    assert result.rows == PgFixtures.rows()
  end

  test "dynamic credentials can filter fixture rows by column", %{name: name} do
    {:ok, _} = register(name)

    %{"username" => user, "password" => pass} = current_creds(name)

    {:ok, conn} = pg_connect(user, pass)
    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)

    result = Postgrex.query!(
      conn,
      "SELECT value FROM #{PgFixtures.table()} WHERE name = $1",
      ["beta"]
    )

    assert result.rows == [["second"]]
  end

  test "each registration issues independent credentials", %{name: name1} do
    name2 = :"dynamic_pg_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> RotatingSecrets.deregister(name2) end)

    {:ok, _} = register(name1)
    {:ok, _} = register(name2)

    creds1 = current_creds(name1)
    creds2 = current_creds(name2)

    # OpenBao issues a unique PostgreSQL role per credential request
    assert creds1["username"] != creds2["username"]

    # Both role connections can read fixture data independently
    {:ok, conn1} = pg_connect(creds1["username"], creds1["password"])
    {:ok, conn2} = pg_connect(creds2["username"], creds2["password"])
    on_exit(fn -> if Process.alive?(conn1), do: GenServer.stop(conn1) end)
    on_exit(fn -> if Process.alive?(conn2), do: GenServer.stop(conn2) end)

    count = fn conn ->
      %{rows: [[n]]} = Postgrex.query!(conn, "SELECT count(*) FROM #{PgFixtures.table()}", [])
      n
    end

    assert count.(conn1) == 3
    assert count.(conn2) == 3
  end

  test "revoked credentials can no longer connect to PostgreSQL", %{name: name} do
    {:ok, _} = register(name)
    %{"username" => user, "password" => pass} = current_creds(name)

    # Confirm credentials work before deregister
    assert {:ok, conn_before} = pg_connect(user, pass)
    GenServer.stop(conn_before)

    # Deregister calls Dynamic.terminate/1 → PUT /v1/sys/leases/revoke.
    # The OpenBao database plugin then executes revocation_statements
    # (DROP ROLE IF EXISTS "{{name}}") synchronously before returning.
    RotatingSecrets.deregister(name)

    # A new connection with the same credentials must now fail:
    # the PostgreSQL role no longer exists.
    assert {:error, _} = pg_connect(user, pass)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp register(name) do
    RotatingSecrets.register(name,
      source: RotatingSecrets.Source.Vault.Dynamic,
      source_opts: [
        address: OpenBaoHelper.base_url(),
        token: OpenBaoHelper.root_token(),
        mount: "database",
        path: "test-role"
      ]
    )
  end

  defp current_creds(name) do
    {:ok, secret} = RotatingSecrets.current(name)
    Jason.decode!(Secret.expose(secret))
  end

  defp pg_connect(username, password) do
    # sync_connect: true establishes the TCP socket synchronously, but
    # PostgreSQL auth completes asynchronously in DBConnection 2.x — so
    # start_link can return {:ok, conn} before the handshake finishes.
    # Two additional measures make this reliable for auth-failure assertions:
    #
    #   1. Process.unlink/1 immediately after start_link: if the connection
    #      process later crashes (auth rejected), the EXIT signal does not
    #      propagate to the test process.
    #
    #   2. SELECT 1 forces the auth handshake to complete synchronously.
    #      Postgrex.query/4 uses a monitor (not a link) for the call, so it
    #      returns {:error, reason} on auth failure rather than crashing the
    #      caller.
    case Postgrex.start_link(
      hostname: System.get_env("PG_HOST", "127.0.0.1"),
      port: String.to_integer(System.get_env("PG_PORT", "5432")),
      database: System.get_env("PG_DB", "postgres"),
      username: username,
      password: password,
      sync_connect: true,
      backoff_type: :stop
    ) do
      {:ok, conn} ->
        # Unlink so a crashing connection process doesn't kill the test process.
        Process.unlink(conn)

        # GenServer.call (used internally by Postgrex.query) re-raises any
        # :exit from the called process. Catch it and normalise to {:error, _}.
        try do
          case Postgrex.query(conn, "SELECT 1", [], timeout: 3_000) do
            {:ok, _} ->
              {:ok, conn}

            {:error, reason} ->
              if Process.alive?(conn), do: GenServer.stop(conn, :normal, 1_000)
              {:error, reason}
          end
        catch
          :exit, reason ->
            {:error, {:exit, reason}}
        end

      {:error, _} = err ->
        err
    end
  end
end
