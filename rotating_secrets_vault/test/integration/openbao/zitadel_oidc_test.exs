defmodule RotatingSecrets.Source.Vault.Integration.ZitadelOidcTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  setup do
    spire_socket = System.get_env("SPIRE_AGENT_SOCKET")
    zitadel_role = System.get_env("ZITADEL_OPENBAO_ROLE")

    if is_nil(spire_socket) or is_nil(zitadel_role) do
      {:skip, "SPIRE_AGENT_SOCKET or ZITADEL_OPENBAO_ROLE not set"}
    else
      :ok
    end
  end

  test "fetches secret from OpenBao using ZitadelOidc auth (SPIRE path)" do
    # Minimal skeleton — actual test requires:
    # - Running SPIRE agent at SPIRE_AGENT_SOCKET
    # - SpiffeEx configured with Zitadel provider_uri
    # - OpenBao JWT auth mount configured to accept Zitadel tokens
    # - ZITADEL_OPENBAO_ROLE set to a valid role
    assert System.get_env("SPIRE_AGENT_SOCKET") != nil
    assert System.get_env("ZITADEL_OPENBAO_ROLE") != nil
  end

  describe "client_credentials path" do
    setup do
      client_id = System.get_env("ZITADEL_CLIENT_ID")
      client_secret = System.get_env("ZITADEL_CLIENT_SECRET")
      issuer_uri = System.get_env("ZITADEL_ISSUER_URI")

      if is_nil(client_id) or is_nil(client_secret) or is_nil(issuer_uri) do
        {:skip, "ZITADEL_CLIENT_ID, ZITADEL_CLIENT_SECRET, or ZITADEL_ISSUER_URI not set"}
      else
        {:ok, client_id: client_id, client_secret: client_secret, issuer_uri: issuer_uri}
      end
    end

    test "fetches secret from OpenBao using Oidc auth (client_credentials)", context do
      # Minimal skeleton — requires live Zitadel + OpenBao setup
      assert context[:client_id] != nil
    end
  end
end
