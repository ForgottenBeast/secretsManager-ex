defmodule RotatingSecrets.Source.Vault.HTTP do
  @moduledoc false

  @spec base_request(keyword()) :: Req.Request.t()
  def base_request(opts) do
    address = Keyword.fetch!(opts, :address)
    token = Keyword.fetch!(opts, :token)
    namespace = Keyword.get(opts, :namespace)
    req_options = Keyword.get(opts, :req_options, [])

    base_opts =
      [base_url: address, retry: false, headers: build_headers(token, namespace)] ++ req_options

    Req.new(base_opts)
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

  @spec normalise_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          {:ok, map()} | {:error, atom()}
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

  def normalise_response({:error, _}), do: {:error, :vault_unexpected_error}

  defp build_headers(token, nil), do: [{"x-vault-token", token}]

  defp build_headers(token, namespace) do
    [{"x-vault-token", token}, {"x-vault-namespace", namespace}]
  end
end
