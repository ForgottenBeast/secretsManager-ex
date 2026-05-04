defmodule RotatingSecrets.Source.Vault.OptsPropertyTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RotatingSecrets.Source.Vault.Opts

  # Test 1: validate_path_component rejects traversal/injection inputs
  property "validate_path_component/1 rejects dangerous segments" do
    check all(
            segment <- member_of(["", "..", "a\0b", "a\rb", "a\nb"]),
            max_runs: 100
          ) do
      assert {:error, _} = Opts.validate_path_component(segment)
    end
  end

  # Test 2: validate_path_component accepts valid segments
  property "validate_path_component/1 accepts valid path segments" do
    check all(
            segment <- member_of(["my.app", "transit", "kv", "key-name", "123", "prod_db"]),
            max_runs: 100
          ) do
      assert :ok = Opts.validate_path_component(segment)
    end
  end

  # Test 3: validate_path/1 rejects paths with traversal segments
  property "validate_path/1 rejects paths containing .. segments" do
    check all(
            path <- member_of(["../sys", "kv/../admin", "..", "a/../../etc"]),
            max_runs: 100
          ) do
      assert {:error, _} = Opts.validate_path(path)
    end
  end

  # Test 4: validate_path/1 accepts valid hierarchical paths
  property "validate_path/1 accepts valid nested paths" do
    check all(
            path <- member_of(["secret/data/myapp", "kv/nested", "transit", "my.app/keys"]),
            max_runs: 100
          ) do
      assert :ok = Opts.validate_path(path)
    end
  end

  # Test 5: validate_namespace/1 rejects CRLF/null injection
  property "validate_namespace/1 rejects CRLF and null bytes" do
    check all(
            ns <- member_of(["ns\r\nX-Evil: h", "ns\0", "\r\n", "valid\0"]),
            max_runs: 100
          ) do
      assert {:error, _} = Opts.validate_namespace(ns)
    end
  end
end
