defmodule RotatingSecretsVault.Integration.DynamicTest do
  use ExUnit.Case, async: false

  @moduletag :openbao_db

  alias RotatingSecrets.Secret

  setup_all do
    OpenBaoHelper.setup_database_engine!(OpenBaoHelper.pg_connection_url())
    on_exit(fn -> OpenBaoHelper.teardown_database_engine!() end)
    :ok
  end

  setup do
    name = :"dynamic_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> RotatingSecrets.deregister(name) end)
    {:ok, name: name}
  end

  defp dynamic_opts do
    [
      address: OpenBaoHelper.base_url(),
      token: OpenBaoHelper.root_token(),
      mount: "database",
      path: "test-role"
    ]
  end

  test "fetches database credentials from OpenBao", %{name: name} do
    {:ok, _} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.Dynamic,
        source_opts: dynamic_opts()
      )

    {:ok, secret} = RotatingSecrets.current(name)
    material = Secret.expose(secret)
    creds = Jason.decode!(material)

    assert Map.has_key?(creds, "username")
    assert Map.has_key?(creds, "password")
  end

  test "meta contains lease_id, lease_duration_ms, ttl_seconds", %{name: name} do
    {:ok, _} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.Dynamic,
        source_opts: dynamic_opts()
      )

    {:ok, secret} = RotatingSecrets.current(name)
    meta = Secret.meta(secret)

    assert is_binary(meta.lease_id)
    assert String.starts_with?(meta.lease_id, "database/creds/")
    assert meta.lease_duration_ms > 0
    assert meta.ttl_seconds > 0
  end

  test "lease renewal keeps same credentials", %{name: name} do
    # The database role has default_ttl: "30s" (configured in setup_all via OpenBaoHelper).
    # The registry uses trunc(ttl_seconds * 1000 * 2/3) ≈ 20_000ms before triggering refresh.
    # At refresh, Dynamic.load/1 attempts PUT /v1/sys/leases/renew first.
    # On success, it returns the SAME material with a new TTL.
    # Do NOT set fallback_interval_ms — it has no effect when ttl_seconds is present in meta.
    {:ok, _} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.Dynamic,
        source_opts: dynamic_opts()
      )

    {:ok, sub_ref} = RotatingSecrets.subscribe(name)

    {:ok, s1} = RotatingSecrets.current(name)
    initial_material = Secret.expose(s1)
    initial_lease_id = Secret.meta(s1).lease_id

    # Wait for rotation event (~20s refresh cycle, 90s timeout for CI headroom)
    assert_receive {:rotating_secret_rotated, ^sub_ref, ^name, _}, 90_000

    {:ok, s2} = RotatingSecrets.current(name)

    # Same credentials — lease was renewed, not re-fetched
    assert Secret.expose(s2) == initial_material
    # Same lease ID — the lease was renewed in place
    assert Secret.meta(s2).lease_id == initial_lease_id
  end

  @tag timeout: 120_000
  test "lease revocation on deregister", %{name: name} do
    {:ok, _} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.Dynamic,
        source_opts: dynamic_opts()
      )

    {:ok, secret} = RotatingSecrets.current(name)
    lease_id = Secret.meta(secret).lease_id

    # Deregister triggers terminate/1 → PUT /v1/sys/leases/revoke
    RotatingSecrets.deregister(name)

    # Verify the lease was revoked by attempting to renew it
    client =
      Req.new(
        base_url: OpenBaoHelper.base_url(),
        headers: [{"X-Vault-Token", OpenBaoHelper.root_token()}],
        retry: false
      )

    result = Req.put!(client, url: "/v1/sys/leases/renew", json: %{"lease_id" => lease_id})
    assert result.status in [400, 403, 404]
  end
end
