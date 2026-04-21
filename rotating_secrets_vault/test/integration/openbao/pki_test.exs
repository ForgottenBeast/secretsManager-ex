defmodule RotatingSecretsVault.Integration.PKITest do
  use ExUnit.Case, async: false

  @moduletag :openbao

  alias RotatingSecrets.Secret

  setup_all do
    OpenBaoHelper.setup_pki_engine!()
    on_exit(fn -> OpenBaoHelper.teardown_pki_engine!() end)
    :ok
  end

  setup do
    name = :"pki_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> RotatingSecrets.deregister(name) end)
    {:ok, name: name}
  end

  defp pki_opts(extra \\ []) do
    [
      address: OpenBaoHelper.base_url(),
      token: OpenBaoHelper.root_token(),
      mount: "pki",
      role: "test-role",
      common_name: "test.example.com"
    ] ++ extra
  end

  test "issues certificate and exposes as JSON material", %{name: name} do
    {:ok, _} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.PKI,
        source_opts: pki_opts(ttl: "2m")
      )

    {:ok, secret} = RotatingSecrets.current(name)
    material = Secret.expose(secret)
    assert is_binary(material)

    decoded = Jason.decode!(material)
    assert Map.has_key?(decoded, "certificate")
    assert Map.has_key?(decoded, "private_key")
    assert Map.has_key?(decoded, "issuing_ca")
    assert Map.has_key?(decoded, "ca_chain")
    assert String.starts_with?(decoded["certificate"], "-----BEGIN CERTIFICATE-----")
  end

  test "meta contains serial_number, expiry, ttl_seconds, certificate_fingerprint", %{name: name} do
    {:ok, _} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.PKI,
        source_opts: pki_opts(ttl: "2m")
      )

    {:ok, secret} = RotatingSecrets.current(name)
    meta = Secret.meta(secret)

    assert is_binary(meta.serial_number) and meta.serial_number != ""
    assert meta.ttl_seconds > 0
    assert %DateTime{} = meta.expiry
    assert DateTime.compare(meta.expiry, DateTime.utc_now()) == :gt
    assert String.length(meta.certificate_fingerprint) == 64
    assert meta.certificate_fingerprint =~ ~r/^[0-9a-f]+$/
  end

  test "re-issues certificate on TTL-based refresh", %{name: name} do
    {:ok, _} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.PKI,
        source_opts: pki_opts(ttl: "10s")
      )

    {:ok, sub_ref} = RotatingSecrets.subscribe(name)

    {:ok, initial_secret} = RotatingSecrets.current(name)
    initial_serial = Secret.meta(initial_secret).serial_number

    assert_receive {:rotating_secret_rotated, ^sub_ref, ^name, _}, 30_000

    {:ok, new_secret} = RotatingSecrets.current(name)
    new_serial = Secret.meta(new_secret).serial_number
    assert new_serial != initial_serial
  end

  test "revoke_on_terminate completes without error", %{name: name} do
    {:ok, _} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.PKI,
        source_opts: pki_opts(ttl: "2m", revoke_on_terminate: true)
      )

    {:ok, _secret} = RotatingSecrets.current(name)
    assert :ok = RotatingSecrets.deregister(name)
  end
end
