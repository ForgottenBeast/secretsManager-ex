defmodule RotatingSecrets.Secret do
  @moduledoc """
  An opaque wrapper around a secret value.

  `Secret` prevents accidental exposure through logging, JSON serialisation,
  or string interpolation.  Callers must call `expose/1` explicitly to
  retrieve the raw binary value.

  ## Security guarantees

  - `inspect/1` renders `#RotatingSecrets.Secret<name:redacted>` — the value
    is never included.
  - `String.Chars` and `Jason.Encoder` raise `ArgumentError` so the value
    cannot leak via `"\#{secret}"` or `Jason.encode!/1`.
  - `Phoenix.Param` raises `ArgumentError` so the value cannot appear in a
    URL or controller params.

  ## Usage

      secret = RotatingSecrets.Registry.borrow(:my_secret)
      raw    = RotatingSecrets.Secret.expose(secret)
  """

  @enforce_keys [:name, :value, :meta]
  defstruct [:name, :value, :meta]

  @opaque t :: %__MODULE__{
            name: atom(),
            value: binary(),
            meta: map()
          }

  @doc "Return the raw binary secret value."
  @spec expose(t()) :: binary()
  def expose(%__MODULE__{value: value}), do: value

  @doc "Return the metadata map produced by the source on the last load."
  @spec meta(t()) :: map()
  def meta(%__MODULE__{meta: meta}), do: meta

  @doc "Return the atom name under which the secret is registered."
  @spec name(t()) :: atom()
  def name(%__MODULE__{name: name}), do: name

  defimpl Inspect do
    def inspect(%{name: name}, _opts) do
      "#RotatingSecrets.Secret<#{name}:redacted>"
    end
  end

  defimpl String.Chars do
    def to_string(_secret) do
      raise ArgumentError,
            "RotatingSecrets.Secret cannot be converted to a string. " <>
              "Call RotatingSecrets.Secret.expose/1 explicitly."
    end
  end

  if Code.ensure_loaded?(Jason) do
    defimpl Jason.Encoder do
      def encode(_secret, _opts) do
        raise ArgumentError,
              "RotatingSecrets.Secret cannot be JSON-encoded. " <>
                "Call RotatingSecrets.Secret.expose/1 explicitly."
      end
    end
  end

  if Code.ensure_loaded?(Phoenix.Param) do
    defimpl Phoenix.Param do
      def to_param(_secret) do
        raise ArgumentError,
              "RotatingSecrets.Secret cannot be used as a URL parameter. " <>
                "Call RotatingSecrets.Secret.expose/1 explicitly."
      end
    end
  end
end
