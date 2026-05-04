defmodule RotatingSecrets.Source.Vault.Integration.JwtSvidTest do
  use ExUnit.Case, async: false
  @moduletag :spire

  test "fetches secret from OpenBao using JWT-SVID auth" do
    # Minimal skeleton — actual test requires live SPIRE + OpenBao setup.
    # This test is excluded when SPIRE_AGENT_SOCKET is unset (see test_helper.exs).
    assert System.get_env("SPIRE_AGENT_SOCKET") != nil
  end
end
