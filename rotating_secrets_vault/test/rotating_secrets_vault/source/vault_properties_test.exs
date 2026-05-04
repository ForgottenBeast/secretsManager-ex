defmodule RotatingSecrets.Source.Vault.KvV2PropertiesTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RotatingSecrets.Source.Vault.KvV2

  defp has_required_string_opts?(opts) do
    Enum.all?([:address, :token, :path], fn key ->
      case Keyword.fetch(opts, key) do
        {:ok, val} when is_binary(val) -> true
        _ -> false
      end
    end)
  end

  property "init/1 never returns {:ok, state} with invalid required opts" do
    check all(
            opts <-
              StreamData.list_of(
                StreamData.tuple({StreamData.atom(:alphanumeric), StreamData.term()})
              )
          ) do
      result = KvV2.init(opts)

      if not has_required_string_opts?(opts) do
        assert match?({:error, _}, result)
      end
    end
  end

  property "init/1 never includes :token value in error reason" do
    check all(
            token <- StreamData.binary(min_length: 16),
            opts <-
              StreamData.list_of(
                StreamData.tuple({StreamData.atom(:alphanumeric), StreamData.term()})
              )
          ) do
      opts_with_token = Keyword.put(opts, :token, token)

      case KvV2.init(opts_with_token) do
        {:error, reason} -> refute inspect(reason) =~ token
        _ -> :ok
      end
    end
  end
end
