defmodule RotatingSecrets.GeneratorsTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RotatingSecrets.Generators

  describe "secret_name/0" do
    property "generates atoms prefixed with secret_" do
      check all(name <- Generators.secret_name()) do
        assert is_atom(name)
        assert name |> Atom.to_string() |> String.starts_with?("secret_")
      end
    end
  end

  describe "permanent_error/0" do
    property "generates only known permanent error atoms" do
      check all(error <- Generators.permanent_error()) do
        assert error in [:enoent, :eacces, :not_found, :forbidden]
      end
    end
  end
end
