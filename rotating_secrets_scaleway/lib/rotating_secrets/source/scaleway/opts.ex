defmodule RotatingSecrets.Source.Scaleway.Opts do
  @moduledoc false

  @unsafe_chars ["\0", "\r", "\n"]

  @spec fetch_required_string(keyword(), atom()) :: {:ok, String.t()} | {:error, term()}
  def fetch_required_string(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  @spec fetch_required_positive_integer(keyword(), atom()) ::
          {:ok, pos_integer()} | {:error, term()}
  def fetch_required_positive_integer(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, n} when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  @spec validate_name(String.t()) :: :ok | {:error, term()}
  def validate_name(name) when is_binary(name) and byte_size(name) > 0 do
    cond do
      String.contains?(name, @unsafe_chars) -> {:error, {:invalid_option, :name}}
      name == ".." -> {:error, {:invalid_option, :name}}
      true -> :ok
    end
  end

  def validate_name(_), do: {:error, {:invalid_option, :name}}

  @spec validate_path(nil | String.t()) :: :ok | {:error, term()}
  def validate_path(nil), do: :ok

  def validate_path(path) when is_binary(path) do
    if String.starts_with?(path, "/") do
      segments =
        path
        |> String.split("/")
        |> Enum.drop(1)
        |> Enum.reject(&(&1 == ""))

      Enum.find_value(segments, :ok, fn seg ->
        case validate_segment(seg) do
          :ok -> nil
          err -> err
        end
      end)
    else
      {:error, {:invalid_option, :path}}
    end
  end

  def validate_path(_), do: {:error, {:invalid_option, :path}}

  @spec validate_region(String.t()) :: :ok | {:error, term()}
  def validate_region(region) when is_binary(region) and byte_size(region) > 0 do
    if Regex.match?(~r/\A[a-z0-9-]+\z/, region) do
      :ok
    else
      {:error, {:invalid_option, :region}}
    end
  end

  def validate_region(_), do: {:error, {:invalid_option, :region}}

  @spec validate_key(nil | String.t()) :: :ok | {:error, term()}
  def validate_key(nil), do: :ok

  def validate_key(key) when is_binary(key) and byte_size(key) > 0 do
    if String.contains?(key, @unsafe_chars) do
      {:error, {:invalid_option, :key}}
    else
      :ok
    end
  end

  def validate_key(_), do: {:error, {:invalid_option, :key}}

  defp validate_segment(seg) do
    cond do
      seg == ".." -> {:error, {:invalid_option, :path}}
      String.contains?(seg, @unsafe_chars) -> {:error, {:invalid_option, :path}}
      true -> :ok
    end
  end
end
