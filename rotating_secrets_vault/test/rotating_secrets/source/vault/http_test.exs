defmodule RotatingSecrets.Source.Vault.HTTPTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Source.Vault.HTTP

  @stub_name :http_test

  defp base_req do
    HTTP.base_request(
      address: "http://127.0.0.1:8200",
      token: "s.token",
      req_options: [plug: {Req.Test, @stub_name}]
    )
  end

  describe "normalise_response/1 - success" do
    test "200 returns {:ok, body}" do
      body = %{"data" => %{"value" => "secret"}}
      assert {:ok, ^body} = HTTP.normalise_response({:ok, %Req.Response{status: 200, body: body}})
    end
  end

  describe "normalise_response/1 - HTTP error codes" do
    test "403 returns :vault_auth_error" do
      resp = %Req.Response{status: 403, body: ""}
      assert {:error, :vault_auth_error} = HTTP.normalise_response({:ok, resp})
    end

    test "404 returns :vault_secret_not_found" do
      resp = %Req.Response{status: 404, body: ""}
      assert {:error, :vault_secret_not_found} = HTTP.normalise_response({:ok, resp})
    end

    test "429 returns :vault_rate_limited" do
      resp = %Req.Response{status: 429, body: ""}
      assert {:error, :vault_rate_limited} = HTTP.normalise_response({:ok, resp})
    end

    test "500 returns :vault_server_error" do
      resp = %Req.Response{status: 500, body: ""}
      assert {:error, :vault_server_error} = HTTP.normalise_response({:ok, resp})
    end

    test "503 returns :vault_server_error" do
      resp = %Req.Response{status: 503, body: ""}
      assert {:error, :vault_server_error} = HTTP.normalise_response({:ok, resp})
    end

    test "400 returns :vault_client_error" do
      resp = %Req.Response{status: 400, body: ""}
      assert {:error, :vault_client_error} = HTTP.normalise_response({:ok, resp})
    end

    test "422 returns :vault_client_error" do
      resp = %Req.Response{status: 422, body: ""}
      assert {:error, :vault_client_error} = HTTP.normalise_response({:ok, resp})
    end
  end

  describe "normalise_response/1 - transport errors" do
    test "timeout returns :vault_timeout" do
      err = %Req.TransportError{reason: :timeout}
      assert {:error, :vault_timeout} = HTTP.normalise_response({:error, err})
    end

    test "econnrefused returns :vault_connection_refused" do
      err = %Req.TransportError{reason: :econnrefused}
      assert {:error, :vault_connection_refused} = HTTP.normalise_response({:error, err})
    end

    test "tls_alert returns :vault_tls_error" do
      err = %Req.TransportError{reason: {:tls_alert, :certificate_expired}}
      assert {:error, :vault_tls_error} = HTTP.normalise_response({:error, err})
    end

    test "unknown transport error returns :vault_unexpected_error" do
      err = %Req.TransportError{reason: :unknown_reason}
      assert {:error, :vault_unexpected_error} = HTTP.normalise_response({:error, err})
    end
  end

  describe "get/2 via Req.Test plug" do
    test "happy path returns {:ok, body}" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"data" => "ok"})
      end)

      assert {:ok, %{"data" => "ok"}} = HTTP.get(base_req(), "/v1/secret/data/test")
    end

    test "404 returns :vault_secret_not_found" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      assert {:error, :vault_secret_not_found} = HTTP.get(base_req(), "/v1/secret/data/missing")
    end
  end

  describe "put/3 via Req.Test plug" do
    test "200 with JSON body returns {:ok, body}" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"lease_id" => "abc123"})
      end)

      assert {:ok, %{"lease_id" => "abc123"}} =
               HTTP.put(base_req(), "/v1/secret/data/test", %{"data" => %{"value" => "s3cr3t"}})
    end

    test "403 returns :vault_auth_error" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)

      assert {:error, :vault_auth_error} =
               HTTP.put(base_req(), "/v1/secret/data/test", %{})
    end

    test "404 returns :vault_secret_not_found" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, :vault_secret_not_found} =
               HTTP.put(base_req(), "/v1/secret/data/missing", %{})
    end

    test "500 returns :vault_server_error" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert {:error, :vault_server_error} =
               HTTP.put(base_req(), "/v1/secret/data/test", %{})
    end

    test "transport error returns :vault_connection_refused" do
      Req.Test.stub(@stub_name, fn _conn ->
        raise Req.TransportError, reason: :econnrefused
      end)

      assert {:error, :vault_connection_refused} =
               HTTP.put(base_req(), "/v1/secret/data/test", %{})
    end
  end
end
