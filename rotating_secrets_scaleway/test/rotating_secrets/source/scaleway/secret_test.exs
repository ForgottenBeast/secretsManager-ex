defmodule RotatingSecrets.Source.Scaleway.SecretTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Source.Scaleway.Secret

  @stub_name :scaleway_secret_test

  @valid_opts [
    secret_key: "scw-secret-key-xxxxx",
    project_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    name: "my-secret",
    region: "fr-par",
    ttl_seconds: 300
  ]

  @secret_id "11111111-2222-3333-4444-555555555555"
  @raw_material "super-secret-value"
  @b64_material Base.encode64(@raw_material)

  defp stub_opts(extra \\ []) do
    @valid_opts
    |> Keyword.put(:req_options, plug: {Req.Test, @stub_name})
    |> Keyword.merge(extra)
  end

  # Stubs both API calls based on path
  defp stub_happy(material \\ @raw_material, version \\ 1) do
    b64 = Base.encode64(material)

    Req.Test.stub(@stub_name, fn conn ->
      if String.contains?(conn.request_path, "/versions/current/access") do
        Req.Test.json(conn, %{"payload" => b64, "revision" => version})
      else
        Req.Test.json(conn, %{"secrets" => [%{"id" => @secret_id}]})
      end
    end)
  end

  describe "init/1" do
    test "returns {:ok, state} with valid opts" do
      assert {:ok, state} = Secret.init(@valid_opts)
      assert state.name == "my-secret"
      assert state.region == "fr-par"
      assert state.ttl_seconds == 300
      assert state.path == "/"
      assert state.key == nil
    end

    test "error for missing :secret_key" do
      opts = Keyword.delete(@valid_opts, :secret_key)
      assert {:error, {:invalid_option, :secret_key}} = Secret.init(opts)
    end

    test "error for missing :project_id" do
      opts = Keyword.delete(@valid_opts, :project_id)
      assert {:error, {:invalid_option, :project_id}} = Secret.init(opts)
    end

    test "error for missing :name" do
      opts = Keyword.delete(@valid_opts, :name)
      assert {:error, {:invalid_option, :name}} = Secret.init(opts)
    end

    test "error for missing :region" do
      opts = Keyword.delete(@valid_opts, :region)
      assert {:error, {:invalid_option, :region}} = Secret.init(opts)
    end

    test "error for missing :ttl_seconds" do
      opts = Keyword.delete(@valid_opts, :ttl_seconds)
      assert {:error, {:invalid_option, :ttl_seconds}} = Secret.init(opts)
    end

    test "error for ttl_seconds zero" do
      opts = Keyword.put(@valid_opts, :ttl_seconds, 0)
      assert {:error, {:invalid_option, :ttl_seconds}} = Secret.init(opts)
    end

    test "error for ttl_seconds negative" do
      opts = Keyword.put(@valid_opts, :ttl_seconds, -10)
      assert {:error, {:invalid_option, :ttl_seconds}} = Secret.init(opts)
    end

    test "error for ttl_seconds non-integer" do
      opts = Keyword.put(@valid_opts, :ttl_seconds, "300")
      assert {:error, {:invalid_option, :ttl_seconds}} = Secret.init(opts)
    end

    test "accepts custom :path" do
      opts = Keyword.put(@valid_opts, :path, "/my-app/")
      assert {:ok, state} = Secret.init(opts)
      assert state.path == "/my-app/"
    end

    test "accepts custom :key" do
      opts = Keyword.put(@valid_opts, :key, "password")
      assert {:ok, state} = Secret.init(opts)
      assert state.key == "password"
    end

    test "error for invalid :region" do
      opts = Keyword.put(@valid_opts, :region, "INVALID REGION!")
      assert {:error, {:invalid_option, :region}} = Secret.init(opts)
    end
  end

  describe "init/1 input validation" do
    test "rejects CRLF in name" do
      opts = Keyword.put(@valid_opts, :name, "name\r\nevil")
      assert {:error, {:invalid_option, :name}} = Secret.init(opts)
    end

    test "rejects null byte in name" do
      opts = Keyword.put(@valid_opts, :name, "name\0evil")
      assert {:error, {:invalid_option, :name}} = Secret.init(opts)
    end

    test "rejects path traversal in path" do
      opts = Keyword.put(@valid_opts, :path, "/../etc/passwd")
      assert {:error, {:invalid_option, :path}} = Secret.init(opts)
    end

    test "error tuple does not contain secret_key value" do
      opts = Keyword.delete(@valid_opts, :name)
      {:error, reason} = Secret.init(opts)
      refute inspect(reason) =~ "scw-secret-key-xxxxx"
    end
  end

  describe "init/1 state" do
    test "secret_id is nil in initial state" do
      assert {:ok, state} = Secret.init(@valid_opts)
      assert state.secret_id == nil
    end

    test "base_req is set" do
      assert {:ok, state} = Secret.init(@valid_opts)
      assert %Req.Request{} = state.base_req
    end
  end

  describe "load/1 - happy path" do
    test "returns decoded material and meta" do
      stub_happy()
      {:ok, state} = Secret.init(stub_opts())
      assert {:ok, material, meta, _state} = Secret.load(state)
      assert material == @raw_material
      assert meta.version == 1
      assert meta.ttl_seconds == 300
      assert is_binary(meta.content_hash)
    end

    test "content_hash is SHA-256 of decoded material" do
      stub_happy()
      {:ok, state} = Secret.init(stub_opts())
      assert {:ok, material, meta, _state} = Secret.load(state)
      hash = :crypto.hash(:sha256, material)
      expected = Base.encode16(hash, case: :lower)
      assert meta.content_hash == expected
    end

    test "material is decoded binary, not base64" do
      stub_happy()
      {:ok, state} = Secret.init(stub_opts())
      assert {:ok, material, _meta, _state} = Secret.load(state)
      assert material == @raw_material
      refute material == @b64_material
    end

    test "caches secret_id in returned state" do
      stub_happy()
      {:ok, state} = Secret.init(stub_opts())
      assert {:ok, _material, _meta, new_state} = Secret.load(state)
      assert new_state.secret_id == @secret_id
    end
  end

  describe "load/1 - cached secret_id" do
    test "second load skips list call (only version-access call made)" do
      call_count = :counters.new(1, [])

      Req.Test.stub(@stub_name, fn conn ->
        :counters.add(call_count, 1, 1)

        if String.contains?(conn.request_path, "/versions/current/access") do
          Req.Test.json(conn, %{"payload" => @b64_material, "revision" => 2})
        else
          Req.Test.json(conn, %{"secrets" => [%{"id" => @secret_id}]})
        end
      end)

      {:ok, state} = Secret.init(stub_opts())

      # First load: 2 calls (list + access)
      assert {:ok, _, _, state_after_first} = Secret.load(state)
      first_count = :counters.get(call_count, 1)
      assert first_count == 2

      # Second load: 1 call (only access, secret_id cached)
      assert {:ok, _, _, _} = Secret.load(state_after_first)
      second_count = :counters.get(call_count, 1)
      assert second_count == 3
    end
  end

  describe "load/1 - JSON key extraction" do
    test "extracts named key from JSON payload" do
      json = Jason.encode!(%{"password" => "secret123", "user" => "admin"})
      b64 = Base.encode64(json)

      Req.Test.stub(@stub_name, fn conn ->
        if String.contains?(conn.request_path, "/versions/current/access") do
          Req.Test.json(conn, %{"payload" => b64, "revision" => 1})
        else
          Req.Test.json(conn, %{"secrets" => [%{"id" => @secret_id}]})
        end
      end)

      opts = stub_opts(key: "password")
      {:ok, state} = Secret.init(opts)
      assert {:ok, "secret123", _meta, _state} = Secret.load(state)
    end
  end

  describe "load/1 - JSON key not found" do
    test "returns {:error, :key_not_found, state} when key absent" do
      json = Jason.encode!(%{"other_key" => "value"})
      b64 = Base.encode64(json)

      Req.Test.stub(@stub_name, fn conn ->
        if String.contains?(conn.request_path, "/versions/current/access") do
          Req.Test.json(conn, %{"payload" => b64, "revision" => 1})
        else
          Req.Test.json(conn, %{"secrets" => [%{"id" => @secret_id}]})
        end
      end)

      opts = stub_opts(key: "missing_key")
      {:ok, state} = Secret.init(opts)
      assert {:error, :key_not_found, _state} = Secret.load(state)
    end
  end

  describe "load/1 - non-binary JSON value" do
    test "returns {:error, :invalid_payload, state} when key value is not a string" do
      json = Jason.encode!(%{"count" => 42})
      b64 = Base.encode64(json)

      Req.Test.stub(@stub_name, fn conn ->
        if String.contains?(conn.request_path, "/versions/current/access") do
          Req.Test.json(conn, %{"payload" => b64, "revision" => 1})
        else
          Req.Test.json(conn, %{"secrets" => [%{"id" => @secret_id}]})
        end
      end)

      opts = stub_opts(key: "count")
      {:ok, state} = Secret.init(opts)
      assert {:error, :invalid_payload, _state} = Secret.load(state)
    end
  end

  describe "load/1 - secret not found" do
    test "empty secrets list returns {:error, :not_found, state}" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"secrets" => []})
      end)

      {:ok, state} = Secret.init(stub_opts())
      assert {:error, :not_found, _state} = Secret.load(state)
    end
  end

  describe "load/1 - malformed response" do
    test "response without secrets key returns {:error, {:connection_error, :malformed_response}, state}" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"data" => "unexpected"})
      end)

      {:ok, state} = Secret.init(stub_opts())
      assert {:error, {:connection_error, :malformed_response}, _state} = Secret.load(state)
    end
  end

  describe "load/1 - version 404 (TOCTOU)" do
    test "404 on version access returns transient error and invalidates cached secret_id" do
      Req.Test.stub(@stub_name, fn conn ->
        if String.contains?(conn.request_path, "/versions/current/access") do
          Plug.Conn.send_resp(conn, 404, "")
        else
          Req.Test.json(conn, %{"secrets" => [%{"id" => @secret_id}]})
        end
      end)

      {:ok, state} = Secret.init(stub_opts())
      # Pre-populate secret_id to test invalidation
      state_with_cached = Map.put(state, :secret_id, @secret_id)

      assert {:error, {:connection_error, :scaleway_version_not_found}, new_state} =
               Secret.load(state_with_cached)

      assert new_state.secret_id == nil
    end
  end

  describe "load/1 - HTTP errors" do
    test "401 on list call returns :forbidden" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 401, "")
      end)

      {:ok, state} = Secret.init(stub_opts())
      assert {:error, :forbidden, _state} = Secret.load(state)
    end

    test "403 on list call returns :forbidden" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 403, "")
      end)

      {:ok, state} = Secret.init(stub_opts())
      assert {:error, :forbidden, _state} = Secret.load(state)
    end

    test "429 on list call returns bare :scaleway_rate_limited atom" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 429, "")
      end)

      {:ok, state} = Secret.init(stub_opts())
      assert {:error, :scaleway_rate_limited, _state} = Secret.load(state)
    end

    test "503 on list call returns bare :scaleway_server_error atom" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 503, "")
      end)

      {:ok, state} = Secret.init(stub_opts())
      assert {:error, :scaleway_server_error, _state} = Secret.load(state)
    end

    test "403 on version access returns :forbidden" do
      Req.Test.stub(@stub_name, fn conn ->
        if String.contains?(conn.request_path, "/versions/current/access") do
          Plug.Conn.send_resp(conn, 403, "")
        else
          Req.Test.json(conn, %{"secrets" => [%{"id" => @secret_id}]})
        end
      end)

      {:ok, state} = Secret.init(stub_opts())
      assert {:error, :forbidden, _state} = Secret.load(state)
    end

    test "429 on version access returns bare :scaleway_rate_limited atom" do
      Req.Test.stub(@stub_name, fn conn ->
        if String.contains?(conn.request_path, "/versions/current/access") do
          Plug.Conn.send_resp(conn, 429, "")
        else
          Req.Test.json(conn, %{"secrets" => [%{"id" => @secret_id}]})
        end
      end)

      {:ok, state} = Secret.init(stub_opts())
      assert {:error, :scaleway_rate_limited, _state} = Secret.load(state)
    end

    test "503 on version access returns bare :scaleway_server_error atom" do
      Req.Test.stub(@stub_name, fn conn ->
        if String.contains?(conn.request_path, "/versions/current/access") do
          Plug.Conn.send_resp(conn, 503, "")
        else
          Req.Test.json(conn, %{"secrets" => [%{"id" => @secret_id}]})
        end
      end)

      {:ok, state} = Secret.init(stub_opts())
      assert {:error, :scaleway_server_error, _state} = Secret.load(state)
    end
  end

  describe "load/1 - invalid base64 payload" do
    test "returns {:error, :invalid_payload, state} for non-base64 payload" do
      Req.Test.stub(@stub_name, fn conn ->
        if String.contains?(conn.request_path, "/versions/current/access") do
          Req.Test.json(conn, %{"payload" => "not-valid-base64!!!", "revision" => 1})
        else
          Req.Test.json(conn, %{"secrets" => [%{"id" => @secret_id}]})
        end
      end)

      {:ok, state} = Secret.init(stub_opts())
      assert {:error, :invalid_payload, _state} = Secret.load(state)
    end
  end

  describe "non-load callbacks" do
    test "subscribe_changes/1 returns :not_supported" do
      {:ok, state} = Secret.init(@valid_opts)
      assert :not_supported = Secret.subscribe_changes(state)
    end

    test "handle_change_notification/2 returns :ignored" do
      {:ok, state} = Secret.init(@valid_opts)
      assert :ignored = Secret.handle_change_notification(:any_msg, state)
    end

    test "terminate/1 returns :ok" do
      {:ok, state} = Secret.init(@valid_opts)
      assert :ok = Secret.terminate(state)
    end
  end
end
