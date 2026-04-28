defmodule RotatingSecretsVault.Integration.UnixSocketTest do
  use ExUnit.Case, async: false

  @moduletag :unix_socket

  alias RotatingSecrets.Secret

  setup_all do
    socket_path = System.fetch_env!("BAO_UNIX_SOCKET")
    {:ok, socket_path: socket_path}
  end

  setup ctx do
    prefix = "test-unix-#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      OpenBaoHelper.delete_path!("secret", prefix)
    end)

    {:ok, Map.put(ctx, :prefix, prefix)}
  end

  test "reads KV v2 secret through UNIX domain socket", %{socket_path: socket_path, prefix: prefix} do
    path = "#{prefix}/unix_key"
    OpenBaoHelper.write_secret!("secret", path, %{"value" => "unix-socket-secret"})

    {:ok, _pid} =
      RotatingSecrets.register(:unix_socket_key,
        source: RotatingSecrets.Source.Vault.KvV2,
        source_opts: [
          address: "http://localhost",
          unix_socket: socket_path,
          token: OpenBaoHelper.root_token(),
          path: path,
          mount: "secret"
        ]
      )

    on_exit(fn -> RotatingSecrets.deregister(:unix_socket_key) end)

    {:ok, secret} = RotatingSecrets.current(:unix_socket_key)
    assert Secret.expose(secret) == "unix-socket-secret"
  end
end
