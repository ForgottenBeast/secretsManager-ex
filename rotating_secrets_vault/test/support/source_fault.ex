defmodule SourceFault do
  @moduledoc """
  Test helper: wraps a real Source and can inject controlled failures.

  Use `SourceFault.arm!(name)` to make subsequent load/1 calls return
  {:error, {:connection_error, :econnrefused}, state} until disarmed.
  The initial successful value is served from the inner source.
  """

  @behaviour RotatingSecrets.Source

  def init(opts) do
    inner_source = Keyword.fetch!(opts, :source)
    inner_opts = Keyword.get(opts, :source_opts, [])
    # atom, used to look up fault state
    fault_name = Keyword.fetch!(opts, :fault_name)

    {:ok, inner_state} = inner_source.init(inner_opts)

    case Agent.start_link(fn -> false end, name: fault_name) do
      {:ok, _} -> {:ok, %{source: inner_source, inner: inner_state, fault_name: fault_name}}
      {:error, reason} -> {:error, reason}
    end
  end

  def load(%{fault_name: name} = state) do
    if Agent.get(name, & &1) do
      {:error, {:connection_error, :econnrefused}, state}
    else
      case state.source.load(state.inner) do
        {:ok, v, meta, new_inner} -> {:ok, v, meta, %{state | inner: new_inner}}
        err -> err
      end
    end
  end

  def subscribe_changes(_state), do: :not_supported

  # Public API for tests
  def arm!(fault_name), do: Agent.update(fault_name, fn _ -> true end)
  def disarm!(fault_name), do: Agent.update(fault_name, fn _ -> false end)
end
