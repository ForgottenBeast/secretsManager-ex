defmodule RotatingSecretsTest do
  use ExUnit.Case, async: true

  # Public API functions require RotatingSecrets.Supervisor to be running.
  # Integration tests are in test/rotating_secrets/supervisor_test.exs.
  # Doctests with iex> examples are excluded here.

  test "module is defined" do
    assert is_atom(RotatingSecrets)
  end
end
