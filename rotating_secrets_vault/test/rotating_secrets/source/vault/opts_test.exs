defmodule RotatingSecrets.Source.Vault.OptsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Source.Vault.Opts

  describe "fetch_optional_token/1" do
    test "returns {:ok, token} when token is present" do
      assert {:ok, "s.token"} = Opts.fetch_optional_token(token: "s.token")
    end

    test "returns error when token missing and no unix_socket or agent_mode" do
      assert {:error, _} = Opts.fetch_optional_token([])
    end

    test "returns {:ok, nil} when unix_socket set and no token" do
      assert {:ok, nil} = Opts.fetch_optional_token(unix_socket: "/run/bao.sock")
    end

    test "returns {:ok, nil} when agent_mode true and no token" do
      assert {:ok, nil} = Opts.fetch_optional_token(agent_mode: true)
    end

    test "returns {:ok, token} when both unix_socket and token present" do
      assert {:ok, "s.token"} =
               Opts.fetch_optional_token(unix_socket: "/run/bao.sock", token: "s.token")
    end
  end

  describe "validate_auth/1" do
    test "nil returns {:ok, nil}" do
      assert {:ok, nil} = Opts.validate_auth(nil)
    end

    test "valid :jwt_svid tuple returns {:ok, {:jwt_svid, opts}}" do
      jwt_opts = [spiffe_ex: :my_agent, audience: "https://vault.example.com", role: "my-role"]
      assert {:ok, {:jwt_svid, ^jwt_opts}} = Opts.validate_auth({:jwt_svid, jwt_opts})
    end

    test "missing :spiffe_ex returns error" do
      jwt_opts = [audience: "https://vault.example.com", role: "my-role"]
      assert {:error, {:invalid_option, :spiffe_ex}} = Opts.validate_auth({:jwt_svid, jwt_opts})
    end

    test "missing :audience returns error" do
      jwt_opts = [spiffe_ex: :my_agent, role: "my-role"]
      assert {:error, {:invalid_option, :audience}} = Opts.validate_auth({:jwt_svid, jwt_opts})
    end

    test "bad auth type returns error" do
      assert {:error, {:invalid_option, :auth}} = Opts.validate_auth("bad")
    end

    test "accepts {:oidc, opts} with all required fields" do
      assert {:ok, {:oidc, _}} =
               Opts.validate_auth(
                 {:oidc,
                  [
                    issuer_uri: "https://example.com",
                    client_id: "my-client",
                    client_secret: "my-secret",
                    role: "my-role"
                  ]}
               )
    end

    test "rejects {:oidc, opts} missing :issuer_uri" do
      assert {:error, {:invalid_option, :issuer_uri}} =
               Opts.validate_auth({:oidc, [client_id: "c", client_secret: "s", role: "r"]})
    end

    test "rejects {:oidc, opts} missing :client_id" do
      assert {:error, {:invalid_option, :client_id}} =
               Opts.validate_auth(
                 {:oidc, [issuer_uri: "https://x.com", client_secret: "s", role: "r"]}
               )
    end

    test "rejects {:oidc, opts} missing :client_secret" do
      assert {:error, {:invalid_option, :client_secret}} =
               Opts.validate_auth(
                 {:oidc, [issuer_uri: "https://x.com", client_id: "c", role: "r"]}
               )
    end

    test "rejects {:oidc, opts} missing :role" do
      assert {:error, {:invalid_option, :role}} =
               Opts.validate_auth(
                 {:oidc, [issuer_uri: "https://x.com", client_id: "c", client_secret: "s"]}
               )
    end

    test "rejects {:oidc, opts} with empty :client_secret" do
      assert {:error, {:invalid_option, :client_secret}} =
               Opts.validate_auth(
                 {:oidc,
                  [issuer_uri: "https://x.com", client_id: "c", client_secret: "", role: "r"]}
               )
    end
  end

  describe "fetch_required_atom/2" do
    test "returns {:ok, atom} for atom value" do
      assert {:ok, :foo} = Opts.fetch_required_atom([k: :foo], :k)
    end

    test "returns error for string value" do
      assert {:error, {:invalid_option, :k}} = Opts.fetch_required_atom([k: "string"], :k)
    end
  end

  describe "fetch_optional_token/1 - auth key present" do
    test "returns {:ok, nil} when :auth is set (jwt_svid tuple)" do
      assert {:ok, nil} = Opts.fetch_optional_token(auth: {:jwt_svid, []})
    end
  end

  describe "validate_unix_socket/1" do
    test "nil returns :ok" do
      assert :ok = Opts.validate_unix_socket(nil)
    end

    test "valid path returns :ok" do
      assert :ok = Opts.validate_unix_socket("/run/bao.sock")
    end

    test "empty string returns error" do
      assert {:error, {:invalid_option, :unix_socket}} = Opts.validate_unix_socket("")
    end

    test "integer returns error" do
      assert {:error, {:invalid_option, :unix_socket}} = Opts.validate_unix_socket(123)
    end

    test "path with null byte returns error" do
      assert {:error, {:invalid_option, :unix_socket}} =
               Opts.validate_unix_socket("/run/bao\0sock")
    end

    test "path with newline returns error" do
      assert {:error, {:invalid_option, :unix_socket}} =
               Opts.validate_unix_socket("/run/bao\nsock")
    end

    test "path with carriage return returns error" do
      assert {:error, {:invalid_option, :unix_socket}} =
               Opts.validate_unix_socket("/run/bao\rsock")
    end
  end
end
