# credo:disable-for-this-file Credo.Check.Refactor.ModuleDependencies
# Source.File coordinates FileSystem, Logger, Jason (optional), and multiple
# file/path/format concerns — the dependency count is inherent to its role.
defmodule RotatingSecrets.Source.File do
  @moduledoc """
  A `RotatingSecrets.Source` that reads secrets from a file on disk.

  Supports two modes:

  - `:file_watch` (default) — uses `FileSystem` to watch the **parent directory**
    for `moved_to` and `modified` events. This correctly captures atomic renames
    used by tools such as Vault Agent and systemd-creds.

  - `{:interval, ms}` — no filesystem watch; the source schedules its own
    periodic refresh timer and triggers a reload every `ms` milliseconds.

  ## Options

    * `:path` — path to the secret file. Required.
    * `:mode` — `:file_watch` or `{:interval, ms}`. Default: `:file_watch`.
    * `:format` — `:raw` (return trimmed binary) or `:json` (decode with Jason).
      Default: `:raw`.

  ## File permissions

  `init/1` emits a Logger warning if the file exists and is group- or
  world-readable (mode bits `0o077` non-zero). The process does not crash —
  the warning is advisory.

  ## Example

      RotatingSecrets.register(:db_password,
        source: RotatingSecrets.Source.File,
        source_opts: [path: "/run/secrets/db_password"]
      )
  """

  @behaviour RotatingSecrets.Source

  require Logger

  @doc """
  Initialises the file source state, validates `:path`, `:mode`, and `:format` options,
  and emits a Logger warning if the file has unsafe permissions.
  """
  @impl RotatingSecrets.Source
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    mode = Keyword.get(opts, :mode, :file_watch)
    format = Keyword.get(opts, :format, :raw)

    with :ok <- validate_mode(mode),
         :ok <- validate_format(format) do
      check_permissions(path)
      {:ok, %{path: path, mode: mode, format: format, watcher_pid: nil, timer_ref: nil}}
    end
  end

  @doc """
  Reads the secret from the file at `state.path`, applying the configured `:format`.
  Returns `{:ok, material, meta, state}` on success or `{:error, reason, state}` on failure.
  """
  @impl RotatingSecrets.Source
  def load(state) do
    case Elixir.File.read(state.path) do
      {:ok, content} ->
        {:ok, format_content(content, state.format), %{}, state}

      {:error, :enoent} ->
        {:error, :enoent, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @doc """
  Starts watching for changes according to the configured `:mode`.
  In `:file_watch` mode, watches the parent directory for filesystem events.
  In `{:interval, ms}` mode, schedules a periodic timer message.
  """
  @impl RotatingSecrets.Source
  def subscribe_changes(%{mode: :file_watch} = state) do
    parent_dir = Path.dirname(state.path)
    {:ok, watcher_pid} = FileSystem.start_link(dirs: [parent_dir])
    FileSystem.subscribe(watcher_pid)
    ref = make_ref()
    {:ok, ref, %{state | watcher_pid: watcher_pid}}
  end

  def subscribe_changes(%{mode: {:interval, ms}} = state) do
    ref = make_ref()
    Process.send_after(self(), {:file_interval_tick, ref}, ms)
    {:ok, ref, %{state | timer_ref: ref}}
  end

  @doc """
  Processes filesystem or timer messages and returns `{:changed, state}` when the
  watched file is modified, or `:ignored` for unrelated messages.
  """
  @impl RotatingSecrets.Source
  def handle_change_notification(
        {:file_event, _pid, {path, events}},
        %{mode: :file_watch} = state
      ) do
    target = Path.basename(state.path)

    if Path.basename(path) == target and
         Enum.any?(events, &(&1 in [:modified, :moved_to, :created])) do
      {:changed, state}
    else
      :ignored
    end
  end

  def handle_change_notification(
        {:file_event, _pid, :stop},
        %{mode: :file_watch} = state
      ) do
    {:ok, _ref, new_state} = subscribe_changes(%{state | watcher_pid: nil})
    {:changed, new_state}
  end

  def handle_change_notification(
        {:file_interval_tick, ref},
        %{mode: {:interval, ms}} = state
      )
      when ref == state.timer_ref do
    new_ref = make_ref()
    Process.send_after(self(), {:file_interval_tick, new_ref}, ms)
    {:changed, %{state | timer_ref: new_ref}}
  end

  def handle_change_notification(_msg, _state), do: :ignored

  @doc """
  Cleans up resources: stops the `FileSystem` watcher process if active,
  or cancels the interval timer. Returns `:ok`.
  """
  @impl RotatingSecrets.Source
  def terminate(%{watcher_pid: pid}) when is_pid(pid) do
    GenServer.stop(pid)
    :ok
  end

  def terminate(%{timer_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  def terminate(_state), do: :ok

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_mode(:file_watch), do: :ok
  defp validate_mode({:interval, ms}) when is_integer(ms) and ms > 0, do: :ok
  defp validate_mode(other), do: {:error, {:invalid_option, {:mode, other}}}

  defp validate_format(:raw), do: :ok
  defp validate_format(:json), do: :ok
  defp validate_format(other), do: {:error, {:invalid_option, {:format, other}}}

  defp format_content(content, :raw), do: String.trim_trailing(content)

  if Code.ensure_loaded?(Jason) do
    defp format_content(content, :json), do: Jason.decode!(content)
  else
    defp format_content(_content, :json) do
      raise RuntimeError,
            "RotatingSecrets.Source.File: format: :json requires the :jason dependency. " <>
              "Add `{:jason, \"~> 1.0\"}` to your mix.exs deps."
    end
  end

  defp check_permissions(path) do
    case Elixir.File.stat(path) do
      {:ok, %{mode: mode}} ->
        if Bitwise.band(mode, 0o077) != 0 do
          Logger.warning(
            "RotatingSecrets.Source.File: secret file is group- or world-readable",
            path: path
          )
        end

      _ ->
        :ok
    end
  end
end
