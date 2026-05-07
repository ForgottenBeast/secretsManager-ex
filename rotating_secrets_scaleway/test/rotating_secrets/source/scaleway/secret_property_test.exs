defmodule RotatingSecrets.Source.Scaleway.SecretPropertyTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RotatingSecrets.Source.Scaleway.Secret

  @valid_opts [
    secret_key: "scw-secret-key-xxxxx",
    project_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    name: "my-secret",
    region: "fr-par",
    ttl_seconds: 300
  ]

  @secret_key_value "scw-secret-key-xxxxx"

  describe "init/1 properties" do
    property "never returns {:ok, state} when a required opt is missing" do
      required_keys = [:secret_key, :project_id, :name, :region, :ttl_seconds]

      check all(key <- member_of(required_keys)) do
        opts = Keyword.delete(@valid_opts, key)
        assert {:error, _} = Secret.init(opts)
      end
    end

    property "never includes secret_key value in error reason" do
      check all(bad_key <- member_of([:name, :region, :project_id, :ttl_seconds])) do
        opts = Keyword.delete(@valid_opts, bad_key)

        case Secret.init(opts) do
          {:error, reason} ->
            refute inspect(reason) =~ @secret_key_value

          {:ok, _state} ->
            flunk("Expected error but got ok for deleted key #{bad_key}")
        end
      end
    end
  end
end
