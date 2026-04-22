defmodule RotatingSecrets.Source.Vault.TransitTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Source.Vault.Transit

  @stub_name :transit_test
  @valid_opts [address: "http://127.0.0.1:8200", mount: "transit", name: "test-key", token: "root"]

  defp stub_opts(opts), do: opts ++ [req_options: [plug: {Req.Test, @stub_name}]]

  defp transit_keys_response(latest_version \\ 1, min_decryption_version \\ 1) do
    %{
      "data" => %{
        "name"                   => "test-key",
        "type"                   => "aes256-gcm96",
        "latest_version"         => latest_version,
        "min_decryption_version" => min_decryption_version,
        "min_encryption_version" => 0,
        "deletion_allowed"       => false,
        "exportable"             => false,
        "supports_encryption"    => true,
        "supports_decryption"    => true,
        "supports_derivation"    => true,
        "supports_signing"       => false
      }
    }
  end

  # ---------------------------------------------------------------------------
  # init/1
  # ---------------------------------------------------------------------------

  describe "init/1" do
    test "ok with required opts — state has :base_req, :mount, :name" do
      assert {:ok, state} = Transit.init(stub_opts(@valid_opts))
      assert Map.has_key?(state, :base_req)
      assert state.mount == "transit"
      assert state.name == "test-key"
    end

    test "error for missing :address" do
      opts = Keyword.delete(@valid_opts, :address)
      assert {:error, {:invalid_option, :address}} = Transit.init(opts)
    end

    test "error for missing :mount" do
      opts = Keyword.delete(@valid_opts, :mount)
      assert {:error, {:invalid_option, :mount}} = Transit.init(opts)
    end

    test "error for missing :name" do
      opts = Keyword.delete(@valid_opts, :name)
      assert {:error, {:invalid_option, :name}} = Transit.init(opts)
    end

    test "error for missing :token" do
      opts = Keyword.delete(@valid_opts, :token)
      assert {:error, {:invalid_option, :token}} = Transit.init(opts)
    end

    test "error for invalid :namespace (empty string)" do
      opts = Keyword.put(@valid_opts, :namespace, "")
      assert {:error, {:invalid_option, :namespace}} = Transit.init(opts)
    end
  end

  # ---------------------------------------------------------------------------
  # load/1 - success
  # ---------------------------------------------------------------------------

  describe "load/1 - success" do
    test "happy path: returns {:ok, material, meta, state} with version 1" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, transit_keys_response(1))
      end)

      {:ok, state} = Transit.init(stub_opts(@valid_opts))
      assert {:ok, material, meta, _new_state} = Transit.load(state)
      assert Jason.decode!(material)["latest_version"] == 1
      assert meta.version == 1
      assert meta.key_type == "aes256-gcm96"
      assert meta.min_decryption_version == 1
    end

    test "version > 1: returns meta.version == 3 and material latest_version == 3" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, transit_keys_response(3))
      end)

      {:ok, state} = Transit.init(stub_opts(@valid_opts))
      assert {:ok, material, meta, _new_state} = Transit.load(state)
      assert meta.version == 3
      assert Jason.decode!(material)["latest_version"] == 3
    end

    test "JSON round-trip: decoded material latest_version matches meta.version" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, transit_keys_response(2))
      end)

      {:ok, state} = Transit.init(stub_opts(@valid_opts))
      assert {:ok, material, meta, _new_state} = Transit.load(state)
      assert Jason.decode!(material)["latest_version"] == meta.version
    end
  end

  # ---------------------------------------------------------------------------
  # load/1 - HTTP errors
  # ---------------------------------------------------------------------------

  describe "load/1 - HTTP errors" do
    test "403 returns :vault_auth_error" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)
      {:ok, state} = Transit.init(stub_opts(@valid_opts))
      assert {:error, :vault_auth_error, _} = Transit.load(state)
    end

    test "404 returns :vault_secret_not_found" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      {:ok, state} = Transit.init(stub_opts(@valid_opts))
      assert {:error, :vault_secret_not_found, _} = Transit.load(state)
    end

    test "transport error :econnrefused returns :vault_connection_refused" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      {:ok, state} = Transit.init(stub_opts(@valid_opts))
      assert {:error, :vault_connection_refused, _} = Transit.load(state)
    end
  end

  # ---------------------------------------------------------------------------
  # terminate/1
  # ---------------------------------------------------------------------------

  describe "terminate/1" do
    test "returns :ok with no HTTP calls" do
      assert :ok = Transit.terminate(%{})
    end
  end
end
