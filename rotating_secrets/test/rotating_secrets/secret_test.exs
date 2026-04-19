defmodule RotatingSecrets.SecretTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Secret

  @name :my_db_password
  @value "s3cr3t!"
  @meta %{version: 7, content_hash: "abc123"}

  defp secret do
    struct!(Secret, name: @name, value: @value, meta: @meta)
  end

  describe "expose/1" do
    test "returns the raw binary value" do
      assert Secret.expose(secret()) == @value
    end
  end

  describe "name/1" do
    test "returns the atom name" do
      assert Secret.name(secret()) == @name
    end
  end

  describe "meta/1" do
    test "returns the meta map" do
      assert Secret.meta(secret()) == @meta
    end
  end

  describe "Inspect" do
    test "does not include the secret value" do
      output = inspect(secret())
      refute String.contains?(output, @value)
    end

    test "includes the name and 'redacted'" do
      output = inspect(secret())
      assert String.contains?(output, to_string(@name))
      assert String.contains?(output, "redacted")
    end

    test "renders the expected format" do
      assert inspect(secret()) == "#RotatingSecrets.Secret<my_db_password:redacted>"
    end
  end

  describe "String.Chars" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, fn -> to_string(secret()) end
    end

    test "interpolation raises ArgumentError" do
      assert_raise ArgumentError, fn -> "#{secret()}" end
    end
  end

  if Code.ensure_loaded?(Jason) do
    describe "Jason.Encoder" do
      test "Jason.encode!/1 raises ArgumentError" do
        assert_raise ArgumentError, fn -> Jason.encode!(secret()) end
      end

      test "nested in a map raises ArgumentError" do
        assert_raise ArgumentError, fn -> Jason.encode!(%{secret: secret()}) end
      end
    end
  end
end
