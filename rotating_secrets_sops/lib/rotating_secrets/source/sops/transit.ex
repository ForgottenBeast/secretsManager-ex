# credo:disable-for-this-file Credo.Check.Refactor.ModuleDependencies
# Source.Sops.Transit has the same multi-concern structure as Source.Sops —
# the dependency count is inherent to coordinating file I/O, crypto, and
# the Source behaviour.
defmodule RotatingSecrets.Source.Sops.Transit do
  @moduledoc """
  A `RotatingSecrets.Source` that loads a raw encryption key from a
  SOPS-encrypted key file.

  Intended for use with `RotatingSecrets.Source.Sops.Transit.Operations`:
  the Registry holds the current key material and the application calls
  `Transit.Operations.encrypt/2` or `decrypt/2` with it.

  The key file must decrypt to exactly **32 bytes** (256 bits) — the key
  length required by AES-256-GCM. Any other length causes `load/1` to
  return `{:error, :invalid_key_length, state}`.

  Unlike `Source.Sops`, this source has no `:format` option. The sops
  invocation always uses `--output-type binary`.

  ## Options

  Same as `RotatingSecrets.Source.Sops` except `:format` is absent:

    * `:path` — path to the SOPS-encrypted key file. Required.
    * `:sops_binary` — default: `"sops"`.
    * `:mode` — `:file_watch` or `{:interval, ms}`. Default: `:file_watch`.
    * `:sops_args` — extra CLI arguments. Default: `[]`.
    * `:timeout` — sops execution timeout in ms. Default: `30_000`.
    * `:cmd_fn` — test injection override. Default: `&System.cmd/3`.

  ## Example

      RotatingSecrets.register(:enc_key,
        source: RotatingSecrets.Source.Sops.Transit,
        source_opts: [path: "/secrets/enc_key.enc"]
      )

      secret = RotatingSecrets.borrow(:enc_key)
      key    = RotatingSecrets.Secret.expose(secret)

      {:ok, ciphertext} = RotatingSecrets.Source.Sops.Transit.Operations.encrypt(key, plaintext)
  """

  @behaviour RotatingSecrets.Source

  require Logger

  @sops_exit_not_found 100

  @type cmd_fn :: (binary(), [binary()], keyword() -> {binary(), non_neg_integer()})

  @impl RotatingSecrets.Source
  def init(opts) do
    with {:ok, path} <- fetch_path(opts),
         {:ok, sops_binary} <- fetch_sops_binary(opts),
         {:ok, mode} <- fetch_mode(opts),
         {:ok, sops_args} <- fetch_sops_args(opts),
         {:ok, timeout} <- fetch_timeout(opts) do
      check_permissions(path)

      cmd_fn = Keyword.get(opts, :cmd_fn, &System.cmd/3)

      {:ok,
       %{
         path: path,
         sops_binary: sops_binary,
         mode: mode,
         sops_args: sops_args,
         timeout: timeout,
         cmd_fn: cmd_fn,
         watcher_pid: nil,
         timer_ref: nil
       }}
    end
  end

  @impl RotatingSecrets.Source
  def load(state) do
    args = state.sops_args ++ ["--decrypt", "--output-type", "binary", state.path]

    case run_sops(state, args) do
      {output, 0} ->
        case byte_size(output) do
          32 ->
            raw_hash = :crypto.hash(:sha256, output)
            hash = Base.encode16(raw_hash, case: :lower)

            meta = %{
              version: nil,
              ttl_seconds: nil,
              content_hash: hash,
              key_length: 32
            }

            {:ok, output, meta, state}

          actual ->
            Logger.warning(
              "RotatingSecrets.Source.Sops.Transit: key material is not 32 bytes",
              path: state.path,
              actual_bytes: actual
            )

            {:error, :invalid_key_length, state}
        end

      {_output, @sops_exit_not_found} ->
        {:error, :not_found, state}

      {output, code} when is_integer(code) ->
        {:error, {:sops_error, code, output}, state}

      :timeout ->
        Logger.warning(
          "RotatingSecrets.Source.Sops.Transit: sops timed out",
          path: state.path,
          timeout_ms: state.timeout
        )

        {:error, :sops_timeout, state}
    end
  end

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
  # Private helpers (same as Source.Sops)
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

  defp fetch_mode(opts) do
    case Keyword.get(opts, :mode, :file_watch) do
      :file_watch -> {:ok, :file_watch}
      {:interval, ms} when is_integer(ms) and ms > 0 -> {:ok, {:interval, ms}}
      other -> {:error, {:invalid_option, {:mode, other}}}
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
            "RotatingSecrets.Source.Sops.Transit: encrypted key file is group- or world-readable",
            path: path
          )
        end

      _ ->
        :ok
    end
  end
end
