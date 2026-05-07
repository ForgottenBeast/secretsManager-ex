defmodule RotatingSecrets.Source.Scaleway.HTTPTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Source.Scaleway.HTTP

  @stub_name :scaleway_http_test
  @region "fr-par"
  @secret_key "scw-secret-key-test"

  defp base_opts(extra \\ []) do
    [
      region: @region,
      secret_key: @secret_key,
      req_options: [plug: {Req.Test, @stub_name}]
    ] ++ extra
  end

  describe "base_request/1" do
    test "base_url includes region" do
      req = HTTP.base_request(base_opts())

      assert req.options.base_url ==
               "https://api.scaleway.com/secret-manager/v1alpha1/regions/fr-par"
    end

    test "x-auth-token header is set" do
      Req.Test.stub(@stub_name, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-auth-token") == [@secret_key]
        Req.Test.json(conn, %{})
      end)

      req = HTTP.base_request(base_opts())
      HTTP.get(req, "/test")
    end

    test "retry is disabled" do
      req = HTTP.base_request(base_opts())
      assert req.options.retry == false
    end

    test "req_options are merged (test plug is active)" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      req = HTTP.base_request(base_opts())
      assert {:ok, %{"ok" => true}} = HTTP.get(req, "/test")
    end
  end

  describe "normalise_response/1" do
    test "200 returns {:ok, body}" do
      resp = %Req.Response{status: 200, body: %{"key" => "value"}}
      assert {:ok, %{"key" => "value"}} = HTTP.normalise_response({:ok, resp})
    end

    test "401 returns :scaleway_auth_error" do
      resp = %Req.Response{status: 401, body: ""}
      assert {:error, :scaleway_auth_error} = HTTP.normalise_response({:ok, resp})
    end

    test "403 returns :scaleway_auth_error" do
      resp = %Req.Response{status: 403, body: ""}
      assert {:error, :scaleway_auth_error} = HTTP.normalise_response({:ok, resp})
    end

    test "404 returns :scaleway_secret_not_found" do
      resp = %Req.Response{status: 404, body: ""}
      assert {:error, :scaleway_secret_not_found} = HTTP.normalise_response({:ok, resp})
    end

    test "429 returns :scaleway_rate_limited" do
      resp = %Req.Response{status: 429, body: ""}
      assert {:error, :scaleway_rate_limited} = HTTP.normalise_response({:ok, resp})
    end

    test "500 returns :scaleway_server_error" do
      resp = %Req.Response{status: 500, body: ""}
      assert {:error, :scaleway_server_error} = HTTP.normalise_response({:ok, resp})
    end

    test "503 returns :scaleway_server_error" do
      resp = %Req.Response{status: 503, body: ""}
      assert {:error, :scaleway_server_error} = HTTP.normalise_response({:ok, resp})
    end

    test "other status returns :scaleway_client_error" do
      resp = %Req.Response{status: 400, body: ""}
      assert {:error, :scaleway_client_error} = HTTP.normalise_response({:ok, resp})
    end

    test "timeout transport error" do
      err = %Req.TransportError{reason: :timeout}
      assert {:error, :scaleway_timeout} = HTTP.normalise_response({:error, err})
    end

    test "econnrefused transport error" do
      err = %Req.TransportError{reason: :econnrefused}
      assert {:error, :scaleway_connection_refused} = HTTP.normalise_response({:error, err})
    end

    test "tls_alert transport error" do
      err = %Req.TransportError{reason: {:tls_alert, :handshake_failure}}
      assert {:error, :scaleway_tls_error} = HTTP.normalise_response({:error, err})
    end

    test "unknown transport error returns :scaleway_transport_error" do
      err = %Req.TransportError{reason: :some_unknown_reason}
      assert {:error, :scaleway_transport_error} = HTTP.normalise_response({:error, err})
    end
  end

  describe "get/2 - happy path" do
    test "returns {:ok, body} on 200" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"secrets" => []})
      end)

      req = HTTP.base_request(base_opts())
      assert {:ok, %{"secrets" => []}} = HTTP.get(req, "/secrets")
    end
  end

  describe "get/2 - HTTP error responses" do
    test "returns error atom on 403" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 403, "")
      end)

      req = HTTP.base_request(base_opts())
      assert {:error, :scaleway_auth_error} = HTTP.get(req, "/secrets")
    end

    test "returns error atom on 404" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 404, "")
      end)

      req = HTTP.base_request(base_opts())
      assert {:error, :scaleway_secret_not_found} = HTTP.get(req, "/secrets")
    end
  end
end
