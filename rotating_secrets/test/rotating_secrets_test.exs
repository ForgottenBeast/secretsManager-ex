defmodule RotatingSecretsTest do
  use ExUnit.Case
  doctest RotatingSecrets

  test "greets the world" do
    assert RotatingSecrets.hello() == :world
  end
end
