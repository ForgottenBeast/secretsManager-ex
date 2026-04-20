defmodule RotatingSecrets.SubscriberFanoutPropertiesTest do
  @moduledoc """
  Property: all N subscribers receive exactly one :rotating_secret_rotated
  notification per rotation event.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import Mox

  alias RotatingSecrets.Generators
  alias RotatingSecrets.MockSource
  alias RotatingSecrets.Registry

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(MockSource, :terminate, fn _state -> :ok end)
    stub(MockSource, :subscribe_changes, fn _state -> :not_supported end)
    :ok
  end

  property "every subscriber receives exactly one notification per rotation" do
    check all(
            n <- Generators.subscriber_count(),
            max_runs: 15
          ) do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      name = :"prop_fanout_#{System.unique_integer([:positive])}"  # unique test atom, not user-controlled

      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state -> {:ok, "value", %{version: 1}, state} end)

      opts = [name: name, source: MockSource, source_opts: [], fallback_interval_ms: 60_000]
      start_supervised!({Registry, opts}, id: name)

      test_pid = self()

      sub_refs =
        Enum.map(1..n, fn _ ->
          subscriber =
            spawn(fn ->
              {:ok, sub_ref} = GenServer.call(name, {:subscribe, self()})
              send(test_pid, {:subscribed, sub_ref})

              receive do
                {:rotating_secret_rotated, ^sub_ref, _, _} ->
                  send(test_pid, {:notified, sub_ref})
              after
                500 -> send(test_pid, {:timeout, sub_ref})
              end
            end)

          receive do
            {:subscribed, sub_ref} ->
              {subscriber, sub_ref}
          after
            500 -> flunk("subscriber did not register in time")
          end
        end)

      # Trigger one rotation
      send(name, :do_refresh)

      # Collect results
      Enum.each(sub_refs, fn {_pid, sub_ref} ->
        assert_receive {:notified, ^sub_ref}, 500
      end)

      # No double-notifications
      Enum.each(sub_refs, fn {_pid, sub_ref} ->
        refute_receive {:notified, ^sub_ref}, 50
      end)

      stop_supervised!(name)
    end
  end
end
