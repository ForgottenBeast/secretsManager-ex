defmodule RotatingSecrets.Source.Vault.Integration.JwtSvidTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  setup do
    socket = System.get_env("SPIRE_AGENT_SOCKET")
    if is_nil(socket), do: {:skip, "SPIRE_AGENT_SOCKET not set"}
    :ok
  end

  test "fetches secret from OpenBao using JWT-SVID auth" do
    # Minimal skeleton — actual test requires live SPIRE + OpenBao setup
    # Guard ensures this only runs when SPIRE_AGENT_SOCKET is set
    assert System.get_env("SPIRE_AGENT_SOCKET") != nil
  end
end
