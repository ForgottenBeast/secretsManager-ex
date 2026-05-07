defmodule RotatingSecrets.Source.Scaleway.OptsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Source.Scaleway.Opts

  describe "fetch_required_string/2" do
    test "returns {:ok, value} for a non-empty binary" do
      assert {:ok, "hello"} = Opts.fetch_required_string([key: "hello"], :key)
    end

    test "error for missing key" do
      assert {:error, {:invalid_option, :key}} = Opts.fetch_required_string([], :key)
    end

    test "error for empty string" do
      assert {:error, {:invalid_option, :key}} = Opts.fetch_required_string([key: ""], :key)
    end

    test "error for non-binary value" do
      assert {:error, {:invalid_option, :key}} = Opts.fetch_required_string([key: 123], :key)
    end

    test "error for nil value" do
      assert {:error, {:invalid_option, :key}} = Opts.fetch_required_string([key: nil], :key)
    end
  end

  describe "fetch_required_positive_integer/2" do
    test "returns {:ok, n} for a positive integer" do
      assert {:ok, 300} = Opts.fetch_required_positive_integer([ttl: 300], :ttl)
    end

    test "error for missing key" do
      assert {:error, {:invalid_option, :ttl}} = Opts.fetch_required_positive_integer([], :ttl)
    end

    test "error for zero" do
      assert {:error, {:invalid_option, :ttl}} =
               Opts.fetch_required_positive_integer([ttl: 0], :ttl)
    end

    test "error for negative integer" do
      assert {:error, {:invalid_option, :ttl}} =
               Opts.fetch_required_positive_integer([ttl: -1], :ttl)
    end

    test "error for non-integer" do
      assert {:error, {:invalid_option, :ttl}} =
               Opts.fetch_required_positive_integer([ttl: "300"], :ttl)
    end

    test "error for nil" do
      assert {:error, {:invalid_option, :ttl}} =
               Opts.fetch_required_positive_integer([ttl: nil], :ttl)
    end
  end

  describe "validate_name/1" do
    test "accepts a valid name" do
      assert :ok = Opts.validate_name("my-secret")
    end

    test "accepts names with dots and underscores" do
      assert :ok = Opts.validate_name("my.secret_name")
    end

    test "error for empty string" do
      assert {:error, {:invalid_option, :name}} = Opts.validate_name("")
    end

    test "error for non-binary" do
      assert {:error, {:invalid_option, :name}} = Opts.validate_name(nil)
    end

    test "error for CRLF injection" do
      assert {:error, {:invalid_option, :name}} = Opts.validate_name("name\r\nevil")
    end

    test "error for null byte" do
      assert {:error, {:invalid_option, :name}} = Opts.validate_name("name\0evil")
    end

    test "error for newline" do
      assert {:error, {:invalid_option, :name}} = Opts.validate_name("name\nevil")
    end
  end

  describe "validate_path/1" do
    test "accepts nil (default path)" do
      assert :ok = Opts.validate_path(nil)
    end

    test "accepts root path" do
      assert :ok = Opts.validate_path("/")
    end

    test "accepts nested path" do
      assert :ok = Opts.validate_path("/my-app/")
    end

    test "accepts deeper nested path" do
      assert :ok = Opts.validate_path("/org/team/service/")
    end

    test "accepts path without trailing slash" do
      assert :ok = Opts.validate_path("/my-app")
    end

    test "error for path without leading slash" do
      assert {:error, {:invalid_option, :path}} = Opts.validate_path("my-app/")
    end

    test "error for empty string" do
      assert {:error, {:invalid_option, :path}} = Opts.validate_path("")
    end

    test "error for path traversal" do
      assert {:error, {:invalid_option, :path}} = Opts.validate_path("/../etc/passwd")
    end

    test "error for .. segment in nested path" do
      assert {:error, {:invalid_option, :path}} = Opts.validate_path("/app/../secrets")
    end

    test "error for CRLF in path" do
      assert {:error, {:invalid_option, :path}} = Opts.validate_path("/app\r\nevil/")
    end

    test "error for null byte in path" do
      assert {:error, {:invalid_option, :path}} = Opts.validate_path("/app\0/")
    end

    test "error for non-binary" do
      assert {:error, {:invalid_option, :path}} = Opts.validate_path(42)
    end
  end

  describe "validate_region/1" do
    test "accepts fr-par" do
      assert :ok = Opts.validate_region("fr-par")
    end

    test "accepts nl-ams-1" do
      assert :ok = Opts.validate_region("nl-ams-1")
    end

    test "accepts pl-waw" do
      assert :ok = Opts.validate_region("pl-waw")
    end

    test "error for empty string" do
      assert {:error, {:invalid_option, :region}} = Opts.validate_region("")
    end

    test "error for region with spaces" do
      assert {:error, {:invalid_option, :region}} = Opts.validate_region("fr par")
    end

    test "error for region with special chars" do
      assert {:error, {:invalid_option, :region}} = Opts.validate_region("fr-par!")
    end

    test "error for CRLF injection" do
      assert {:error, {:invalid_option, :region}} = Opts.validate_region("fr-par\r\nevil")
    end

    test "error for uppercase" do
      assert {:error, {:invalid_option, :region}} = Opts.validate_region("FR-PAR")
    end

    test "error for non-binary" do
      assert {:error, {:invalid_option, :region}} = Opts.validate_region(nil)
    end
  end

  describe "validate_key/1" do
    test "accepts nil (no key extraction)" do
      assert :ok = Opts.validate_key(nil)
    end

    test "accepts a valid key" do
      assert :ok = Opts.validate_key("password")
    end

    test "accepts key with dots" do
      assert :ok = Opts.validate_key("db.password")
    end

    test "error for empty string" do
      assert {:error, {:invalid_option, :key}} = Opts.validate_key("")
    end

    test "error for CRLF" do
      assert {:error, {:invalid_option, :key}} = Opts.validate_key("key\r\nevil")
    end

    test "error for null byte" do
      assert {:error, {:invalid_option, :key}} = Opts.validate_key("key\0evil")
    end

    test "error for non-binary non-nil" do
      assert {:error, {:invalid_option, :key}} = Opts.validate_key(42)
    end
  end
end
