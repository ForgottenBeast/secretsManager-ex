defmodule RotatingSecrets.Source.Scaleway.OptsPropertyTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RotatingSecrets.Source.Scaleway.Opts

  describe "validate_name/1 property" do
    property "rejects strings containing control characters" do
      check all(
              prefix <- string(:alphanumeric, min_length: 0, max_length: 10),
              suffix <- string(:alphanumeric, min_length: 0, max_length: 10),
              bad_char <- member_of(["\0", "\r", "\n"])
            ) do
        name = prefix <> bad_char <> suffix
        assert {:error, {:invalid_option, :name}} = Opts.validate_name(name)
      end
    end
  end

  describe "validate_region/1 property" do
    property "accepts strings matching [a-z0-9-]+" do
      check all(region <- string(Enum.concat([?a..?z, ?0..?9, [?-]]), min_length: 1)) do
        assert :ok = Opts.validate_region(region)
      end
    end
  end

  describe "fetch_required_positive_integer/2 property" do
    property "accepts all positive integers" do
      check all(n <- positive_integer()) do
        assert {:ok, ^n} = Opts.fetch_required_positive_integer([key: n], :key)
      end
    end

    property "rejects zero and negative integers" do
      check all(n <- one_of([constant(0), map(positive_integer(), &(-&1))])) do
        assert {:error, {:invalid_option, :key}} =
                 Opts.fetch_required_positive_integer([key: n], :key)
      end
    end
  end

  describe "validate_path/1 property" do
    test "accepts nil" do
      assert :ok = Opts.validate_path(nil)
    end

    property "rejects paths containing .. segments" do
      check all(
              prefix <- string(:alphanumeric, min_length: 0, max_length: 5),
              suffix <- string(:alphanumeric, min_length: 0, max_length: 5)
            ) do
        path = "/#{prefix}/../#{suffix}"
        assert {:error, {:invalid_option, :path}} = Opts.validate_path(path)
      end
    end
  end

  describe "validate_key/1 property" do
    test "accepts nil" do
      assert :ok = Opts.validate_key(nil)
    end
  end
end
