defmodule RotatingSecrets.Source.Vault.PKITest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias RotatingSecrets.Source.Vault.PKI

  @stub_name :pki_test
  @valid_opts [
    address: "http://127.0.0.1:8200",
    mount: "pki",
    role: "web-server",
    token: "s.token",
    common_name: "example.com"
  ]

  defp stub_opts(extra \\ []) do
    @valid_opts
    |> Keyword.put(:req_options, plug: {Req.Test, @stub_name})
    |> Keyword.merge(extra)
  end

  defp make_cert_pem do
    conf =
      :public_key.pkix_test_data(%{
        server_chain: %{root: [], peer: []},
        client_chain: %{root: [], peer: []}
      })

    cert_der = conf[:server_config] |> Keyword.fetch!(:cert)
    :public_key.pem_encode([{:Certificate, cert_der, :not_encrypted}])
  end

  defp pki_issue_response(conn, cert_pem, opts \\ %{}) do
    serial = Map.get(opts, :serial_number, "01:02:03:04")

    Req.Test.json(conn, %{
      "data" => %{
        "certificate" => cert_pem,
        "private_key" => "-----BEGIN RSA PRIVATE KEY-----\nMIIBogIBAAJ\n-----END RSA PRIVATE KEY-----\n",
        "issuing_ca" => "-----BEGIN CERTIFICATE-----\nMIIBCA\n-----END CERTIFICATE-----\n",
        "ca_chain" => ["-----BEGIN CERTIFICATE-----\nMIIBCA\n-----END CERTIFICATE-----\n"],
        "serial_number" => serial
      }
    })
  end

  # ---------------------------------------------------------------------------
  # init/1
  # ---------------------------------------------------------------------------

  describe "init/1" do
    test "ok with required opts" do
      assert {:ok, state} = PKI.init(@valid_opts)
      assert state.mount == "pki"
      assert state.role == "web-server"
      assert state.common_name == "example.com"
    end

    test "revoke_on_terminate defaults to false" do
      assert {:ok, state} = PKI.init(@valid_opts)
      assert state.revoke_on_terminate == false
    end

    test "ok with optional :alt_names, :ttl, :ip_sans stored in state" do
      opts =
        @valid_opts
        |> Keyword.put(:alt_names, ["a.example.com", "b.example.com"])
        |> Keyword.put(:ttl, "72h")
        |> Keyword.put(:ip_sans, ["10.0.0.1"])

      assert {:ok, state} = PKI.init(opts)
      assert state.alt_names == ["a.example.com", "b.example.com"]
      assert state.ttl == "72h"
      assert state.ip_sans == ["10.0.0.1"]
    end

    test "error for missing :address" do
      opts = Keyword.delete(@valid_opts, :address)
      assert {:error, {:invalid_option, :address}} = PKI.init(opts)
    end

    test "error for missing :mount" do
      opts = Keyword.delete(@valid_opts, :mount)
      assert {:error, {:invalid_option, :mount}} = PKI.init(opts)
    end

    test "error for missing :role" do
      opts = Keyword.delete(@valid_opts, :role)
      assert {:error, {:invalid_option, :role}} = PKI.init(opts)
    end

    test "error for missing :token" do
      opts = Keyword.delete(@valid_opts, :token)
      assert {:error, {:invalid_option, :token}} = PKI.init(opts)
    end

    test "error for missing :common_name" do
      opts = Keyword.delete(@valid_opts, :common_name)
      assert {:error, {:invalid_option, :common_name}} = PKI.init(opts)
    end

    test "error for blank :common_name" do
      opts = Keyword.put(@valid_opts, :common_name, "")
      assert {:error, {:invalid_option, :common_name}} = PKI.init(opts)
    end

    test "error for invalid :namespace (empty string)" do
      opts = Keyword.put(@valid_opts, :namespace, "")
      assert {:error, {:invalid_option, :namespace}} = PKI.init(opts)
    end
  end

  describe "init/1 input validation" do
    test "rejects path-traversal mount" do
      opts = Keyword.put(@valid_opts, :mount, "../sys")
      assert {:error, {:invalid_option, :mount}} = PKI.init(opts)
    end

    test "rejects null-byte in mount" do
      opts = Keyword.put(@valid_opts, :mount, "a\0b")
      assert {:error, {:invalid_option, :mount}} = PKI.init(opts)
    end

    test "accepts mount with dots" do
      opts = Keyword.put(@valid_opts, :mount, "my.app")
      assert {:ok, _state} = PKI.init(opts)
    end

    test "rejects CRLF injection in namespace" do
      opts = Keyword.put(@valid_opts, :namespace, "ns\r\nX-Evil: h")
      assert {:error, {:invalid_option, :namespace}} = PKI.init(opts)
    end

    test "rejects path-traversal in role" do
      opts = Keyword.put(@valid_opts, :role, "../admin")
      assert {:error, {:invalid_option, :role}} = PKI.init(opts)
    end
  end

  # ---------------------------------------------------------------------------
  # load/1 - success
  # ---------------------------------------------------------------------------

  describe "load/1 - success" do
    setup do
      cert_pem = make_cert_pem()
      %{cert_pem: cert_pem}
    end

    test "returns {:ok, material, meta, new_state}", %{cert_pem: cert_pem} do
      Req.Test.stub(@stub_name, fn conn -> pki_issue_response(conn, cert_pem) end)

      {:ok, state} = PKI.init(stub_opts())
      assert {:ok, _material, _meta, _new_state} = PKI.load(state)
    end

    test "material is valid JSON with certificate keys", %{cert_pem: cert_pem} do
      Req.Test.stub(@stub_name, fn conn -> pki_issue_response(conn, cert_pem) end)

      {:ok, state} = PKI.init(stub_opts())
      {:ok, material, _meta, _new_state} = PKI.load(state)

      decoded = Jason.decode!(material)
      assert Map.has_key?(decoded, "certificate")
      assert Map.has_key?(decoded, "private_key")
      assert Map.has_key?(decoded, "issuing_ca")
      assert Map.has_key?(decoded, "ca_chain")
    end

    test "meta.version is nil", %{cert_pem: cert_pem} do
      Req.Test.stub(@stub_name, fn conn -> pki_issue_response(conn, cert_pem) end)

      {:ok, state} = PKI.init(stub_opts())
      {:ok, _material, meta, _new_state} = PKI.load(state)
      assert meta.version == nil
    end

    test "meta.serial_number matches response", %{cert_pem: cert_pem} do
      Req.Test.stub(@stub_name, fn conn -> pki_issue_response(conn, cert_pem) end)

      {:ok, state} = PKI.init(stub_opts())
      {:ok, _material, meta, _new_state} = PKI.load(state)
      assert meta.serial_number == "01:02:03:04"
    end

    test "meta.ttl_seconds > 0 (cert expires 2099)", %{cert_pem: cert_pem} do
      Req.Test.stub(@stub_name, fn conn -> pki_issue_response(conn, cert_pem) end)

      {:ok, state} = PKI.init(stub_opts())
      {:ok, _material, meta, _new_state} = PKI.load(state)
      assert meta.ttl_seconds > 0
    end

    test "meta.expiry is a DateTime", %{cert_pem: cert_pem} do
      Req.Test.stub(@stub_name, fn conn -> pki_issue_response(conn, cert_pem) end)

      {:ok, state} = PKI.init(stub_opts())
      {:ok, _material, meta, _new_state} = PKI.load(state)
      assert %DateTime{} = meta.expiry
    end

    test "meta.issued_at is a DateTime", %{cert_pem: cert_pem} do
      Req.Test.stub(@stub_name, fn conn -> pki_issue_response(conn, cert_pem) end)

      {:ok, state} = PKI.init(stub_opts())
      {:ok, _material, meta, _new_state} = PKI.load(state)
      assert %DateTime{} = meta.issued_at
    end

    test "new_state.serial_number is set", %{cert_pem: cert_pem} do
      Req.Test.stub(@stub_name, fn conn -> pki_issue_response(conn, cert_pem) end)

      {:ok, state} = PKI.init(stub_opts())
      {:ok, _material, _meta, new_state} = PKI.load(state)
      assert new_state.serial_number == "01:02:03:04"
    end

    test "meta has no certificate or private_key key (log-safe)", %{cert_pem: cert_pem} do
      Req.Test.stub(@stub_name, fn conn -> pki_issue_response(conn, cert_pem) end)

      {:ok, state} = PKI.init(stub_opts())
      {:ok, _material, meta, _new_state} = PKI.load(state)
      refute Map.has_key?(meta, :certificate)
      refute Map.has_key?(meta, :private_key)
      refute Map.has_key?(meta, "certificate")
      refute Map.has_key?(meta, "private_key")
    end
  end

  # ---------------------------------------------------------------------------
  # load/1 - HTTP errors
  # ---------------------------------------------------------------------------

  describe "load/1 - HTTP errors" do
    test "403 returns :vault_auth_error" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)
      {:ok, state} = PKI.init(stub_opts())
      assert {:error, :vault_auth_error, _} = PKI.load(state)
    end

    test "500 returns :vault_server_error" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)
      {:ok, state} = PKI.init(stub_opts())
      assert {:error, :vault_server_error, _} = PKI.load(state)
    end
  end

  # ---------------------------------------------------------------------------
  # terminate/1
  # ---------------------------------------------------------------------------

  describe "terminate/1" do
    test "revoke_on_terminate false (default) — no HTTP call, returns :ok" do
      Req.Test.stub(@stub_name, fn _conn -> raise "should not be called" end)

      {:ok, state} = PKI.init(stub_opts())
      assert :ok = PKI.terminate(state)
    end

    test "revoke_on_terminate true, serial_number nil — no HTTP call, returns :ok" do
      Req.Test.stub(@stub_name, fn _conn -> raise "should not be called" end)

      {:ok, state} = PKI.init(stub_opts(revoke_on_terminate: true))
      assert state.serial_number == nil
      assert :ok = PKI.terminate(state)
    end

    test "revoke_on_terminate true + serial_number set — calls PUT /v1/{mount}/revoke" do
      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        if conn.request_path == "/v1/pki/revoke" do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:revoke_called, body})
          Plug.Conn.send_resp(conn, 200, Jason.encode!(%{}))
        else
          Plug.Conn.send_resp(conn, 200, Jason.encode!(%{}))
        end
      end)

      {:ok, state} = PKI.init(stub_opts(revoke_on_terminate: true))
      state = %{state | serial_number: "01:02:03"}

      assert :ok = PKI.terminate(state)
      assert_receive {:revoke_called, body}
      assert Jason.decode!(body)["serial_number"] == "01:02:03"
    end

    test "revoke_on_terminate true + vault unreachable — still returns :ok" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      {:ok, state} = PKI.init(stub_opts(revoke_on_terminate: true))
      state = %{state | serial_number: "01:02:03"}

      assert :ok = PKI.terminate(state)
    end
  end

  # ---------------------------------------------------------------------------
  # M3 — SAN extraction logging (rescue clause)
  # ---------------------------------------------------------------------------

  describe "M3 — extract_sans failure logging" do
    setup do
      cert_pem = make_cert_pem()
      %{cert_pem: cert_pem}
    end

    test "normal cert load does not log 'SAN extraction failed'", %{cert_pem: cert_pem} do
      Req.Test.stub(@stub_name, fn conn -> pki_issue_response(conn, cert_pem) end)

      {:ok, state} = PKI.init(stub_opts())

      log = capture_log(fn -> PKI.load(state) end)
      refute log =~ "SAN extraction failed"
    end

    test "meta.sans is always a list after successful load", %{cert_pem: cert_pem} do
      Req.Test.stub(@stub_name, fn conn -> pki_issue_response(conn, cert_pem) end)

      {:ok, state} = PKI.init(stub_opts())
      {:ok, _material, meta, _new_state} = PKI.load(state)

      assert is_list(meta.sans)
    end
  end
end
