defmodule RotatingSecrets.Generators do
  @moduledoc """
  StreamData generators for RotatingSecrets property tests.
  """

  use ExUnitProperties

  @doc "Generates a valid secret name atom."
  def secret_name do
    gen all(str <- string(:alphanumeric, min_length: 1, max_length: 20)) do
      String.to_atom("secret_" <> str)
    end
  end

  @doc "Generates a non-empty binary secret value."
  def secret_value do
    string(:printable, min_length: 1, max_length: 128)
  end

  @doc "Generates a meta map with optional :version and :ttl_seconds."
  def meta_map do
    gen all(
          version <- one_of([nil, integer(1..9999)]),
          ttl <- one_of([nil, integer(1..3600)])
        ) do
      %{}
      |> then(fn m -> if version, do: Map.put(m, :version, version), else: m end)
      |> then(fn m -> if ttl, do: Map.put(m, :ttl_seconds, ttl), else: m end)
    end
  end

  @doc "Generates a permanent error atom as returned by classify_error."
  def permanent_error do
    member_of([:enoent, :eacces, :not_found, :forbidden])
  end

  @doc "Generates a transient error atom."
  def transient_error do
    member_of([:timeout, :econnrefused, :nxdomain, :temporary_failure])
  end

  @doc "Generates a subscriber count (1 to 5)."
  def subscriber_count do
    integer(1..5)
  end
end
