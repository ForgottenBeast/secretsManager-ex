defmodule RotatingSecrets.Source.Vault.Opts do
  @moduledoc false

  @spec fetch_required_string(keyword(), atom()) :: {:ok, String.t()} | {:error, term()}
  def fetch_required_string(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  @spec validate_namespace(String.t() | nil) :: :ok | {:error, term()}
  def validate_namespace(nil), do: :ok
  def validate_namespace(ns) when is_binary(ns) and byte_size(ns) > 0, do: :ok
  def validate_namespace(_), do: {:error, {:invalid_option, :namespace}}
end
