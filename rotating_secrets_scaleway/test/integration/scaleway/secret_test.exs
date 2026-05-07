defmodule RotatingSecrets.Source.Scaleway.Integration.SecretTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias RotatingSecrets.Source.Scaleway.Secret

  @moduletag :scw_integration

  defp integration_opts do
    [
      secret_key: System.fetch_env!("SCW_SECRET_KEY"),
      project_id: System.fetch_env!("SCW_DEFAULT_PROJECT_ID"),
      region: System.get_env("SCW_REGION", "fr-par"),
      name: System.fetch_env!("SCW_TEST_SECRET_NAME"),
      ttl_seconds: 60
    ]
  end

  describe "load/1 against real Scaleway API" do
    test "successfully loads the current version of a secret" do
      {:ok, state} = Secret.init(integration_opts())
      assert {:ok, material, meta, _state} = Secret.load(state)
      assert is_binary(material)
      assert is_integer(meta.version) and meta.version >= 1
      assert is_binary(meta.content_hash)
      assert meta.ttl_seconds == 60
    end

    test "secret_id is cached after first load" do
      {:ok, state} = Secret.init(integration_opts())
      assert {:ok, _material, _meta, state_after} = Secret.load(state)
      assert is_binary(state_after.secret_id)
    end
  end

  describe "load/1 - not found" do
    test "non-existent secret name returns :not_found" do
      base = integration_opts()

      opts =
        Keyword.put(
          base,
          :name,
          "this-secret-does-not-exist-#{System.unique_integer([:positive])}"
        )

      {:ok, state} = Secret.init(opts)
      assert {:error, :not_found, _state} = Secret.load(state)
    end
  end
end
