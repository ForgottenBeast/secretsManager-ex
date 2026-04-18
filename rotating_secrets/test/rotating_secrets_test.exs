defmodule RotatingSecretsTest do
  use ExUnit.Case, async: true
  doctest RotatingSecrets

  test "greets the world" do
    assert RotatingSecrets.hello() == :world
  end
end
