defmodule PgFixtures do
  @moduledoc false

  # A small, deterministic table that lives only for the duration of the
  # :openbao_db integration test suite. SELECT is granted to PUBLIC so that
  # any dynamically-issued Vault credential (which gets LOGIN only) can read
  # rows without additional privilege configuration.

  @table "vault_test_fixtures"

  @rows [
    [1, "alpha", "first"],
    [2, "beta", "second"],
    [3, "gamma", "third"]
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Creates the fixture table, inserts the seed rows, and grants SELECT to PUBLIC.
  Connects as the admin user (postgres/postgres).
  """
  def setup! do
    {:ok, conn} = start_admin_conn()

    Postgrex.query!(conn, "DROP TABLE IF EXISTS #{@table}", [])

    Postgrex.query!(conn, """
    CREATE TABLE #{@table} (
      id    integer PRIMARY KEY,
      name  text    NOT NULL,
      value text    NOT NULL
    )
    """, [])

    Enum.each(@rows, fn [id, name, value] ->
      Postgrex.query!(
        conn,
        "INSERT INTO #{@table} (id, name, value) VALUES ($1, $2, $3)",
        [id, name, value]
      )
    end)

    Postgrex.query!(conn, "GRANT SELECT ON #{@table} TO PUBLIC", [])

    GenServer.stop(conn)
    :ok
  end

  @doc "Drops the fixture table."
  def teardown! do
    {:ok, conn} = start_admin_conn()
    Postgrex.query!(conn, "DROP TABLE IF EXISTS #{@table}", [])
    GenServer.stop(conn)
    :ok
  end

  @doc "The table name exposed to tests."
  def table, do: @table

  @doc "The expected rows in insertion order."
  def rows, do: @rows

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp start_admin_conn do
    Postgrex.start_link(
      hostname: System.get_env("PG_HOST", "127.0.0.1"),
      port: pg_port(),
      database: System.get_env("PG_DB", "postgres"),
      username: "postgres",
      password: "postgres"
    )
  end

  defp pg_port do
    System.get_env("PG_PORT", "5432") |> String.to_integer()
  end
end
