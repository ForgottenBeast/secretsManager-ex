defmodule RotatingSecrets.Testing.Supervisor do
  @moduledoc """
  Supervisor that starts the processes required by `rotating_secrets_testing`.

  Add this to your test supervision tree, or start it in an ExUnit `setup`
  block via `start_supervised!/1`:

      setup do
        start_supervised!(RotatingSecrets.Supervisor)
        start_supervised!(RotatingSecrets.Testing.Supervisor)
        :ok
      end

  Managed processes:

    * `RotatingSecrets.Source.Controllable.Registry` — OTP Registry used by
      `RotatingSecrets.Source.Controllable` to track its Agent processes.
  """

  use Supervisor

  @doc false
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: RotatingSecrets.Source.Controllable.Registry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
