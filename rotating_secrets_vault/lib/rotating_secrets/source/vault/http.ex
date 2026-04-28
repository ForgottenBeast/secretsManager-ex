defmodule RotatingSecrets.Source.Vault.HTTP do
  @moduledoc """
  Internal HTTP client for Vault API requests.

  Mint (the underlying HTTP client) defaults to `verify: :verify_peer` for TLS connections,
  providing certificate validation out of the box.
  """

  @spec base_request(keyword()) :: Req.Request.t()
  def base_request(opts) do
    address     = Keyword.fetch!(opts, :address)
    token       = Keyword.get(opts, :token)
    namespace   = Keyword.get(opts, :namespace)
    req_options = Keyword.get(opts, :req_options, [])
    unix_socket = Keyword.get(opts, :unix_socket)

    base_opts = [base_url: address, retry: false, headers: build_headers(token, namespace)]
    base_opts = if unix_socket, do: Keyword.put(base_opts, :unix_socket, unix_socket), else: base_opts

    Req.new(req_options) |> Req.merge(base_opts)
  end

  @spec get(Req.Request.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def get(base_req, path) do
    try do
      base_req
      |> Req.get(url: path)
      |> normalise_response()
    rescue
      e in Req.TransportError -> normalise_response({:error, e})
    end
  end

  @spec put(Req.Request.t(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def put(base_req, path, body) do
    try do
      base_req
      |> Req.put(url: path, json: body)
      |> normalise_response()
    rescue
      e in Req.TransportError -> normalise_response({:error, e})
    end
  end

  @spec post(Req.Request.t(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def post(base_req, path, body) do
    try do
      base_req |> Req.post(url: path, json: body) |> normalise_response()
    rescue
      e in Req.TransportError -> normalise_response({:error, e})
    end
  end

  @spec delete(Req.Request.t(), String.t()) :: :ok | {:error, atom()}
  def delete(base_req, path) do
    try do
      base_req |> Req.delete(url: path) |> normalise_response_delete()
    rescue
      e in Req.TransportError -> normalise_response({:error, e})
    end
  end

  @spec normalise_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          {:ok, map()} | {:error, atom()}
  def normalise_response({:ok, %Req.Response{status: 204}}), do: {:ok, %{}}
  def normalise_response({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, body}
  def normalise_response({:ok, %Req.Response{status: 403}}), do: {:error, :vault_auth_error}
  def normalise_response({:ok, %Req.Response{status: 404}}), do: {:error, :vault_secret_not_found}
  def normalise_response({:ok, %Req.Response{status: 429}}), do: {:error, :vault_rate_limited}

  def normalise_response({:ok, %Req.Response{status: status}}) when status in 500..599 do
    {:error, :vault_server_error}
  end

  def normalise_response({:ok, %Req.Response{}}), do: {:error, :vault_client_error}

  def normalise_response({:error, %Req.TransportError{reason: :timeout}}) do
    {:error, :vault_timeout}
  end

  def normalise_response({:error, %Req.TransportError{reason: :econnrefused}}) do
    {:error, :vault_connection_refused}
  end

  def normalise_response({:error, %Req.TransportError{reason: {:tls_alert, _}}}) do
    {:error, :vault_tls_error}
  end

  def normalise_response({:error, %Req.TransportError{reason: :enoent}}),
    do: {:error, :vault_socket_not_found}
  def normalise_response({:error, %Req.TransportError{reason: :eacces}}),
    do: {:error, :vault_socket_permission_denied}

  def normalise_response({:error, _}), do: {:error, :vault_unexpected_error}

  defp normalise_response_delete({:ok, %Req.Response{status: s}}) when s in [200, 204], do: :ok
  defp normalise_response_delete({:ok, %Req.Response{status: 404}}), do: :ok
  defp normalise_response_delete(other), do: normalise_response(other)

  defp build_headers(nil, nil), do: []
  defp build_headers(nil, namespace), do: [{"x-vault-namespace", namespace}]
  defp build_headers(token, nil), do: [{"x-vault-token", token}]
  defp build_headers(token, namespace), do: [{"x-vault-token", token}, {"x-vault-namespace", namespace}]
end
