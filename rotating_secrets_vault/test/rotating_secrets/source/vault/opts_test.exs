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
      assert {:ok, "s.token"} = Opts.fetch_optional_token(unix_socket: "/run/bao.sock", token: "s.token")
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
      assert {:error, {:invalid_option, :unix_socket}} = Opts.validate_unix_socket("/run/bao\0sock")
    end

    test "path with newline returns error" do
      assert {:error, {:invalid_option, :unix_socket}} = Opts.validate_unix_socket("/run/bao\nsock")
    end

    test "path with carriage return returns error" do
      assert {:error, {:invalid_option, :unix_socket}} = Opts.validate_unix_socket("/run/bao\rsock")
    end
  end
end
