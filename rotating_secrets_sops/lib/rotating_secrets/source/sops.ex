# credo:disable-for-this-file Credo.Check.Refactor.ModuleDependencies
# Source.Sops coordinates FileSystem, Logger, Jason (optional), Task, and multiple
# file/path/format concerns — the dependency count is inherent to its role.
defmodule RotatingSecrets.Source.Sops do
  @moduledoc """
  A `RotatingSecrets.Source` that decrypts secrets from SOPS-encrypted files.

  Decryption is performed by shelling out to the `sops` binary on each load.
  The source is agnostic to the key-management backend (age, PGP, AWS KMS,
  GCP KMS, Azure Key Vault) — SOPS resolves keys via `.sops.yaml` or inline
  file metadata.

  Supports two refresh modes:

  - `:file_watch` (default) — uses `FileSystem` to watch the **parent directory**
    for `moved_to`, `modified`, and `created` events on the encrypted file.
    This correctly captures atomic renames used by tools such as Vault Agent.

  - `{:interval, ms}` — no filesystem watch; schedules a periodic reload every
    `ms` milliseconds.

  ## Options

    * `:path` — path to the SOPS-encrypted file. Required.
    * `:sops_binary` — name or path of the `sops` executable. Default: `"sops"`.
    * `:format` — `:raw` returns the decrypted binary as-is; `:json` instructs
      sops to emit JSON output, which is returned as a raw binary — the caller
      is responsible for decoding. Default: `:raw`.
    * `:mode` — `:file_watch` or `{:interval, ms}`. Default: `:file_watch`.
    * `:sops_args` — extra arguments prepended to the sops invocation.
      Default: `[]`. Arguments are passed to `execvp` directly — no shell
      expansion occurs.
    * `:timeout` — milliseconds to wait for sops to exit before killing it.
      Default: `30_000`.
    * `:cmd_fn` — `(binary(), [binary()], keyword() -> {binary(), non_neg_integer()})`.
      Defaults to `&System.cmd/3`. Override in tests to avoid shelling out.

  ## Exit-code mapping

  sops exit codes are not formally documented upstream. The mapping below is
  based on sops 3.x behaviour and should be verified on upgrade.

    * `0` — success
    * `100` — file not found (mapped to `:not_found`)
    * other — transient failure (wrapped in `{:sops_error, code, output}`)

  ## File permissions

  `init/1` emits a `Logger.warning` if the encrypted file exists and is
  group- or world-readable (mode bits `0o077` non-zero). The process does
  not crash — the warning is advisory.

  ## Example

      RotatingSecrets.register(:db_password,
        source: RotatingSecrets.Source.Sops,
        source_opts: [path: "/secrets/db_password.enc"]
      )
  """

  @behaviour RotatingSecrets.Source

  require Logger

  # sops 3.x exit code for "file not found". Undocumented upstream.
  @sops_exit_not_found 100

  @type cmd_fn :: (binary(), [binary()], keyword() -> {binary(), non_neg_integer()})

  # ---------------------------------------------------------------------------
  # Source behaviour — init
  # ---------------------------------------------------------------------------

  @doc """
  Validates options and builds the initial source state. No blocking I/O.

  Emits a `Logger.warning` if the encrypted file exists and is group- or
  world-readable.
  """
  @impl RotatingSecrets.Source
  def init(opts) do
    with {:ok, path} <- fetch_path(opts),
         {:ok, sops_binary} <- fetch_sops_binary(opts),
         {:ok, format} <- fetch_format(opts),
         {:ok, mode} <- fetch_mode(opts),
         {:ok, sops_args} <- fetch_sops_args(opts),
         {:ok, timeout} <- fetch_timeout(opts) do
      check_permissions(path)

      cmd_fn = Keyword.get(opts, :cmd_fn, &System.cmd/3)

      {:ok,
       %{
         path: path,
         sops_binary: sops_binary,
         format: format,
         mode: mode,
         sops_args: sops_args,
         timeout: timeout,
         cmd_fn: cmd_fn,
         watcher_pid: nil,
         timer_ref: nil
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Source behaviour — load
  # ---------------------------------------------------------------------------

  @doc """
  Decrypts the SOPS-encrypted file and returns the plaintext material.

  Shells out to `sops --decrypt --output-type <type> <path>`. On success,
  returns `{:ok, material, meta, state}` where `meta` includes a SHA-256
  content hash. On failure, returns `{:error, reason, state}`.
  """
  @impl RotatingSecrets.Source
  def load(state) do
    args =
      state.sops_args ++ ["--decrypt", "--output-type", output_type(state.format), state.path]

    case run_sops(state, args) do
      {output, 0} ->
        hash = sha256_hex(output)
        meta = %{version: nil, ttl_seconds: nil, content_hash: hash}
        {:ok, output, meta, state}

      {_output, @sops_exit_not_found} ->
        {:error, :not_found, state}

      {output, code} when is_integer(code) ->
        {:error, {:sops_error, code, output}, state}

      :timeout ->
        Logger.warning(
          "RotatingSecrets.Source.Sops: sops timed out",
          path: state.path,
          timeout_ms: state.timeout
        )

        {:error, :sops_timeout, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Source behaviour — subscribe_changes
  # ---------------------------------------------------------------------------

  @doc """
  Registers for push change notifications according to the configured `:mode`.

  In `:file_watch` mode, watches the parent directory for filesystem events.
  In `{:interval, ms}` mode, schedules a periodic `:sops_interval_tick` timer.
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
    Process.send_after(self(), {:sops_interval_tick, ref}, ms)
    {:ok, ref, %{state | timer_ref: ref}}
  end

  # ---------------------------------------------------------------------------
  # Source behaviour — handle_change_notification
  # ---------------------------------------------------------------------------

  @doc """
  Returns `{:changed, state}` when the watched file is modified or the
  interval timer fires. Returns `:ignored` for unrelated messages.
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
        {:sops_interval_tick, ref},
        %{mode: {:interval, ms}} = state
      )
      when ref == state.timer_ref do
    new_ref = make_ref()
    Process.send_after(self(), {:sops_interval_tick, new_ref}, ms)
    {:changed, %{state | timer_ref: new_ref}}
  end

  def handle_change_notification(_msg, _state), do: :ignored

  # ---------------------------------------------------------------------------
  # Source behaviour — terminate
  # ---------------------------------------------------------------------------

  @doc """
  Stops the `FileSystem` watcher process or cancels the interval timer.
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

  defp run_sops(state, args) do
    task = Task.async(fn -> state.cmd_fn.(state.sops_binary, args, stderr_to_stdout: true) end)

    case Task.yield(task, state.timeout) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        :timeout
    end
  end

  defp output_type(:raw), do: "binary"
  defp output_type(:json), do: "json"

  defp sha256_hex(data) do
    raw = :crypto.hash(:sha256, data)
    Base.encode16(raw, case: :lower)
  end

  defp fetch_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) and byte_size(path) > 0 ->
        validate_no_null_bytes(path, :path)

      {:ok, other} ->
        {:error, {:invalid_option, {:path, other}}}

      :error ->
        {:error, {:missing_option, :path}}
    end
  end

  defp fetch_sops_binary(opts) do
    binary = Keyword.get(opts, :sops_binary, "sops")

    if is_binary(binary) and byte_size(binary) > 0 do
      validate_no_null_bytes(binary, :sops_binary)
    else
      {:error, {:invalid_option, {:sops_binary, binary}}}
    end
  end

  defp fetch_format(opts) do
    case Keyword.get(opts, :format, :raw) do
      :raw -> {:ok, :raw}
      :json -> {:ok, :json}
      other -> {:error, {:invalid_option, {:format, other}}}
    end
  end

  defp fetch_mode(opts) do
    case Keyword.get(opts, :mode, :file_watch) do
      :file_watch ->
        {:ok, :file_watch}

      {:interval, ms} when is_integer(ms) and ms > 0 ->
        {:ok, {:interval, ms}}

      other ->
        {:error, {:invalid_option, {:mode, other}}}
    end
  end

  defp fetch_sops_args(opts) do
    case Keyword.get(opts, :sops_args, []) do
      args when is_list(args) ->
        if Enum.all?(args, &is_binary/1) do
          {:ok, args}
        else
          {:error, {:invalid_option, {:sops_args, args}}}
        end

      other ->
        {:error, {:invalid_option, {:sops_args, other}}}
    end
  end

  defp fetch_timeout(opts) do
    case Keyword.get(opts, :timeout, 30_000) do
      ms when is_integer(ms) and ms > 0 -> {:ok, ms}
      other -> {:error, {:invalid_option, {:timeout, other}}}
    end
  end

  defp validate_no_null_bytes(value, key) do
    if String.contains?(value, "\0") do
      {:error, {:invalid_option, {key, value}}}
    else
      {:ok, value}
    end
  end

  defp check_permissions(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} ->
        if Bitwise.band(mode, 0o077) != 0 do
          Logger.warning(
            "RotatingSecrets.Source.Sops: encrypted file is group- or world-readable",
            path: path
          )
        end

      _ ->
        :ok
    end
  end
end
