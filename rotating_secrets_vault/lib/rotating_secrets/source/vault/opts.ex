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

  @spec validate_auth(term()) :: {:ok, term()} | {:error, term()}
  def validate_auth(nil), do: {:ok, nil}
  def validate_auth({:jwt_svid, jwt_opts}) when is_list(jwt_opts) do
    validate_jwt_svid_auth(jwt_opts)
  end
  def validate_auth({:oidc, opts}) when is_list(opts), do: validate_oidc_auth(opts)
  def validate_auth(_), do: {:error, {:invalid_option, :auth}}

  @spec validate_jwt_svid_auth(keyword()) :: {:ok, {:jwt_svid, keyword()}} | {:error, term()}
  def validate_jwt_svid_auth(opts) do
    with {:ok, _} <- fetch_required_atom(opts, :spiffe_ex),
         {:ok, _} <- fetch_required_string(opts, :audience),
         {:ok, _} <- fetch_required_string(opts, :role) do
      {:ok, {:jwt_svid, opts}}
    end
  end

  defp validate_oidc_auth(opts) do
    with {:ok, _} <- fetch_required_string(opts, :issuer_uri),
         {:ok, _} <- fetch_required_string(opts, :client_id),
         {:ok, _} <- fetch_required_string(opts, :client_secret),
         {:ok, _} <- fetch_required_string(opts, :role) do
      {:ok, {:oidc, opts}}
    end
  end

  @spec fetch_required_atom(keyword(), atom()) :: {:ok, atom()} | {:error, term()}
  def fetch_required_atom(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} when is_atom(val) -> {:ok, val}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  @spec fetch_optional_token(keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def fetch_optional_token(opts) do
    cond do
      Keyword.get(opts, :auth) != nil -> {:ok, nil}
      Keyword.get(opts, :agent_mode, false) -> {:ok, Keyword.get(opts, :token)}
      Keyword.get(opts, :unix_socket) != nil -> {:ok, Keyword.get(opts, :token)}
      true -> fetch_required_string(opts, :token)
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
