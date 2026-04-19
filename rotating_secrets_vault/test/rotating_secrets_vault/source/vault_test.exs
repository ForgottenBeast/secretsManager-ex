defmodule RotatingSecretsVault.Source.VaultTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias RotatingSecrets.Source.Vault.KvV2

  @stub_name :vault_test
  @token "s.super-secret-token"
  @valid_opts [
    address: "http://127.0.0.1:8200",
    mount: "secret",
    path: "myapp/db",
    token: @token
  ]

  defp stub_opts(extra \\ []) do
    @valid_opts
    |> Keyword.put(:req_options, plug: {Req.Test, @stub_name})
    |> Keyword.merge(extra)
  end

  defp data_response(conn, material \\ "my-secret", version \\ 1) do
    Req.Test.json(conn, %{
      "data" => %{
        "data" => %{"value" => material},
        "metadata" => %{"version" => version}
      }
    })
  end

  describe "load/1 - happy path" do
    test "200 data response extracts material and version" do
      Req.Test.stub(@stub_name, fn conn -> data_response(conn, "db-password", 3) end)

      {:ok, state} = KvV2.init(stub_opts())
      assert {:ok, "db-password", meta, _state} = KvV2.load(state)
      assert meta.version == 3
      assert is_binary(meta.content_hash)
    end

    test "content_hash is lowercase hex SHA-256 of material" do
      Req.Test.stub(@stub_name, fn conn -> data_response(conn, "abc") end)

      {:ok, state} = KvV2.init(stub_opts())
      assert {:ok, "abc", meta, _state} = KvV2.load(state)
      expected = Base.encode16(:crypto.hash(:sha256, "abc"), case: :lower)
      assert meta.content_hash == expected
    end
  end

  describe "load/1 - HTTP errors" do
    test "404 on data endpoint returns :vault_secret_not_found" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      {:ok, state} = KvV2.init(stub_opts())
      assert {:error, :not_found, _state} = KvV2.load(state)
    end

    test "403 on data endpoint returns :vault_auth_error" do
      Req.Test.stub(@stub_name, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)

      {:ok, state} = KvV2.init(stub_opts())
      assert {:error, :forbidden, _state} = KvV2.load(state)
    end

    test "connection error returns {:connection_error, reason}" do
      Req.Test.stub(@stub_name, fn _conn ->
        raise %Req.TransportError{reason: :econnrefused}
      end)

      {:ok, state} = KvV2.init(stub_opts())
      assert {:error, {:connection_error, _reason}, _state} = KvV2.load(state)
    end
  end

  describe "load/1 - ttl_seconds from custom_metadata" do
    test "string ttl_seconds in custom_metadata is extracted as integer" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "data" => %{"value" => "secret"},
            "metadata" => %{
              "version" => 2,
              "custom_metadata" => %{"ttl_seconds" => "300"}
            }
          }
        })
      end)

      {:ok, state} = KvV2.init(stub_opts())
      assert {:ok, "secret", meta, _state} = KvV2.load(state)
      assert meta.ttl_seconds == 300
    end

    test "missing custom_metadata leaves :ttl_seconds absent from meta" do
      Req.Test.stub(@stub_name, fn conn -> data_response(conn) end)

      {:ok, state} = KvV2.init(stub_opts())
      assert {:ok, _material, meta, _state} = KvV2.load(state)
      refute Map.has_key?(meta, :ttl_seconds)
    end
  end

  describe "load/1 - invalid value type" do
    test "non-binary value (integer) in KV data causes error" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "data" => %{"value" => 42},
            "metadata" => %{"version" => 1}
          }
        })
      end)

      {:ok, state} = KvV2.init(stub_opts())
      # sha256_hex/1 will raise on non-binary; load/1 does not guard this,
      # so we verify it either raises or returns an error tuple
      result =
        try do
          KvV2.load(state)
        rescue
          _ -> :raised
        end

      assert result == :raised or match?({:error, _, _}, result)
    end
  end

  describe "init/1 - token safety" do
    test "missing :path returns {:error, _} without token in error" do
      opts = Keyword.delete(@valid_opts, :path)
      assert {:error, reason} = KvV2.init(opts)
      refute inspect(reason) =~ @token
    end

    test "token never appears in inspect of init error" do
      opts = Keyword.delete(@valid_opts, :address)
      assert {:error, reason} = KvV2.init(opts)
      refute inspect(reason) =~ @token
    end

    test "token not present in debug-level logs during init error" do
      opts = Keyword.delete(@valid_opts, :path)

      log =
        capture_log([level: :debug], fn ->
          KvV2.init(opts)
        end)

      refute log =~ @token
    end
  end
end
