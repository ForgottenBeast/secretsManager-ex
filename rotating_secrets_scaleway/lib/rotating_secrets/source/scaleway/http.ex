defmodule RotatingSecrets.Source.Scaleway.HTTP do
  @moduledoc false

  @base_api_url "https://api.scaleway.com/secret-manager/v1alpha1/regions"

  @spec base_request(keyword()) :: Req.Request.t()
  def base_request(opts) do
    region = Keyword.fetch!(opts, :region)
    secret_key = Keyword.fetch!(opts, :secret_key)
    req_options = Keyword.get(opts, :req_options, [])

    base_opts = [
      base_url: "#{@base_api_url}/#{region}",
      retry: false,
      headers: [{"x-auth-token", secret_key}]
    ]

    req_options |> Req.new() |> Req.merge(base_opts)
  end

  @spec get(Req.Request.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def get(base_req, path) do
    base_req
    |> Req.get(url: path)
    |> normalise_response()
  rescue
    e in Req.TransportError -> normalise_response({:error, e})
  end

  @spec normalise_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          {:ok, map()} | {:error, atom()}
  def normalise_response({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, body}
  def normalise_response({:ok, %Req.Response{status: 401}}), do: {:error, :scaleway_auth_error}
  def normalise_response({:ok, %Req.Response{status: 403}}), do: {:error, :scaleway_auth_error}

  def normalise_response({:ok, %Req.Response{status: 404}}),
    do: {:error, :scaleway_secret_not_found}

  def normalise_response({:ok, %Req.Response{status: 429}}), do: {:error, :scaleway_rate_limited}

  def normalise_response({:ok, %Req.Response{status: status}}) when status in 500..599 do
    {:error, :scaleway_server_error}
  end

  def normalise_response({:ok, %Req.Response{}}), do: {:error, :scaleway_client_error}

  def normalise_response({:error, %Req.TransportError{reason: :timeout}}) do
    {:error, :scaleway_timeout}
  end

  def normalise_response({:error, %Req.TransportError{reason: :econnrefused}}) do
    {:error, :scaleway_connection_refused}
  end

  def normalise_response({:error, %Req.TransportError{reason: {:tls_alert, _}}}) do
    {:error, :scaleway_tls_error}
  end

  def normalise_response({:error, _}), do: {:error, :scaleway_transport_error}
end
