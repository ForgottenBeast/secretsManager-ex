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
  def validate_namespace(ns) when is_binary(ns) and byte_size(ns) > 0 do
    if String.contains?(ns, ["\r", "\n", "\0"]) do
      {:error, {:invalid_option, :namespace}}
    else
      :ok
    end
  end
  def validate_namespace(_), do: {:error, {:invalid_option, :namespace}}

  @spec validate_unix_socket(String.t() | nil) :: :ok | {:error, term()}
  def validate_unix_socket(nil), do: :ok
  def validate_unix_socket(path) when is_binary(path) and byte_size(path) > 0 do
    if String.contains?(path, ["\0", "\r", "\n"]),
      do: {:error, {:invalid_option, :unix_socket}},
      else: :ok
  end
  def validate_unix_socket(_), do: {:error, {:invalid_option, :unix_socket}}

  @spec fetch_optional_token(keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def fetch_optional_token(opts) do
    if Keyword.get(opts, :agent_mode, false) || Keyword.get(opts, :unix_socket) do
      {:ok, Keyword.get(opts, :token)}
    else
      fetch_required_string(opts, :token)
    end
  end

  @spec validate_path_component(String.t()) :: :ok | {:error, term()}
  def validate_path_component(segment) when is_binary(segment) do
    cond do
      byte_size(segment) == 0 -> {:error, :empty_segment}
      segment == ".." -> {:error, :path_traversal}
      String.contains?(segment, ["\0", "\r", "\n"]) -> {:error, :invalid_characters}
      true -> :ok
    end
  end
  def validate_path_component(_), do: {:error, :invalid_type}

  @spec validate_path(String.t()) :: :ok | {:error, term()}
  def validate_path(path) when is_binary(path) and byte_size(path) > 0 do
    path
    |> String.split("/")
    |> Enum.find_value(:ok, fn seg ->
      case validate_path_component(seg) do
        :ok -> nil
        error -> error
      end
    end)
  end
  def validate_path(path) when is_binary(path), do: {:error, :empty_path}
  def validate_path(_), do: {:error, :invalid_type}
end
