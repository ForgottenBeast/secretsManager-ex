defmodule OpenBaoHelper do
  @base_url "http://127.0.0.1:8200"
  @root_token "root"

  def start_server!() do
    bin = System.find_executable("bao") ||
          System.get_env("OPENBAO_BIN") ||
          raise "bao binary not found — set OPENBAO_BIN or add bao to PATH"
    port = Port.open({:spawn_executable, bin},
                     [:binary, :exit_status,
                      args: ["server", "-dev",
                             "-dev-root-token-id=root",
                             "-dev-listen-address=127.0.0.1:8200"]])
    wait_for_health!()
    port
  end

  def stop_server!(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  end

  # Poll GET /v1/sys/health until 200 or timeout (10s)
  # Req.get may raise on ECONNREFUSED during startup — rescue to treat as not-yet-ready
  def wait_for_health!(attempts \\ 100) do
    ready =
      try do
        case Req.get("#{@base_url}/v1/sys/health") do
          {:ok, %{status: 200}} -> true
          _ -> false
        end
      rescue
        _ -> false
      end

    if ready do
      :ok
    else
      if attempts > 0 do
        Process.sleep(100)
        wait_for_health!(attempts - 1)
      else
        raise "OpenBao did not become healthy within 10 seconds"
      end
    end
  end

  def write_secret!(mount, path, data, custom_metadata \\ %{}) do
    client = build_client()
    Req.post!(client, url: "/v1/#{mount}/data/#{path}",
              json: %{"data" => data})
    unless map_size(custom_metadata) == 0 do
      Req.post!(client, url: "/v1/#{mount}/metadata/#{path}",
                json: %{"custom_metadata" => custom_metadata})
    end
    :ok
  end

  # Deletes all versions + metadata for a KV path
  def delete_path!(mount, path) do
    client = build_client()
    Req.delete!(client, url: "/v1/#{mount}/metadata/#{path}")
    :ok
  end

  def setup_pki_engine!(mount \\ "pki") do
    client = build_client()
    Req.post!(client, url: "/v1/sys/mounts/#{mount}", json: %{"type" => "pki"})
    Req.post!(client, url: "/v1/#{mount}/root/generate/internal",
              json: %{"common_name" => "Test Root CA", "ttl" => "87600h"})
    Req.post!(client, url: "/v1/#{mount}/roles/test-role",
              json: %{
                "allowed_domains" => ["example.com"],
                "allow_subdomains" => true,
                "max_ttl" => "72h",
                "generate_lease" => true
              })
    :ok
  end

  def teardown_pki_engine!(mount \\ "pki") do
    build_client() |> Req.delete!(url: "/v1/sys/mounts/#{mount}")
    :ok
  end

  def setup_transit_engine!(mount \\ "transit") do
    client = build_client()
    Req.post!(client, url: "/v1/sys/mounts/#{mount}", json: %{"type" => "transit"})
    Req.post!(client, url: "/v1/#{mount}/keys/test-key", json: %{"type" => "aes256-gcm96"})
    :ok
  end

  def teardown_transit_engine!(mount \\ "transit") do
    build_client() |> Req.delete!(url: "/v1/sys/mounts/#{mount}")
    :ok
  end

  def rotate_transit_key!(mount, name) do
    # Transit rotation returns HTTP 204 No Content — use raw Req.post!, NOT HTTP module
    Req.post!(build_client(), url: "/v1/#{mount}/keys/#{name}/rotate", json: %{})
    :ok
  end

  def setup_database_engine!(pg_url, mount \\ "database", role \\ "test-role") do
    client = build_client()
    Req.post!(client, url: "/v1/sys/mounts/#{mount}", json: %{"type" => "database"})
    Req.post!(client, url: "/v1/#{mount}/config/test-postgres",
              json: %{
                "plugin_name" => "postgresql-database-plugin",
                "connection_url" => pg_url,
                "allowed_roles" => [role],
                "username" => "postgres",
                "password" => "postgres"
              })
    Req.post!(client, url: "/v1/#{mount}/roles/#{role}",
              json: %{
                "db_name" => "test-postgres",
                "creation_statements" => [
                  "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';"
                ],
                "default_ttl" => "30s",
                "max_ttl" => "2m"
              })
    :ok
  end

  def teardown_database_engine!(mount \\ "database") do
    build_client() |> Req.delete!(url: "/v1/sys/mounts/#{mount}")
    :ok
  end

  def pg_connection_url do
    host = System.get_env("PG_HOST", "127.0.0.1")
    port = System.get_env("PG_PORT", "5432")
    db   = System.get_env("PG_DB", "postgres")
    "postgresql://{{username}}:{{password}}@#{host}:#{port}/#{db}"
  end

  def base_url, do: @base_url
  def root_token, do: @root_token

  defp build_client do
    Req.new(base_url: @base_url,
            headers: [{"X-Vault-Token", @root_token}])
  end
end
