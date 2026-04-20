defmodule RustConsumerHelper do
  @moduledoc """
  Test helper for managing a Rust secretManager-rs consumer binary.

  ## HTTP JSON Contract

  ### POST /secret
  - Request: `Content-Type: application/json`, body `{"value": "<string>", "version": <integer>}`
  - Response 200: `{"ok": true}`
  - Response 400: `{"error": "bad request"}` (malformed JSON, wrong types)

  ### GET /secret
  - Response 200: `{"value": "<string>", "version": <integer>}`
  - Response 503: `{"error": "not ready"}` (no secret POSTed yet)

  ### GET /health
  - Response 200: `{"status": "ok"}`
  """

  import ExUnit.Assertions

  @timeout_ms 5_000

  def start_server!(binary_path) do
    port = Port.open({:spawn_executable, binary_path},
                     [:binary, :exit_status, args: ["--port", "0"]])
    rust_port = wait_for_port!(port, @timeout_ms)
    {port, rust_port}
  end

  def stop_server!(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  end

  def wait_for_ready!(rust_port, attempts \\ 50) do
    ready =
      try do
        case Req.get("http://127.0.0.1:#{rust_port}/health") do
          {:ok, %{status: 200}} -> true
          _ -> false
        end
      rescue
        _ -> false
      end

    if ready do
      :ok
    else
      if attempts > 0 do
        Process.sleep(100)
        wait_for_ready!(rust_port, attempts - 1)
      else
        raise "Rust consumer did not become ready within timeout"
      end
    end
  end

  def push_secret!(rust_port, value, version) do
    case Req.post("http://127.0.0.1:#{rust_port}/secret",
                  json: %{"value" => value, "version" => version}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> flunk("Rust consumer rejected push: #{status}")
      {:error, reason} -> flunk("Rust consumer push failed: #{inspect(reason)}")
    end
  end

  def get_secret!(rust_port) do
    {:ok, %{body: body}} = Req.get("http://127.0.0.1:#{rust_port}/secret")
    body
  end

  defp wait_for_port!(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_port(port, deadline)
  end

  defp do_wait_for_port(port, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: raise("Timed out waiting for LISTENING_PORT from Rust binary")

    receive do
      {^port, {:data, data}} ->
        case Regex.run(~r/LISTENING_PORT=(\d+)/, data) do
          [_, n] -> String.to_integer(n)
          nil -> do_wait_for_port(port, deadline)
        end
      {^port, {:exit_status, code}} ->
        raise "Rust binary exited with code #{code} before printing LISTENING_PORT"
    after
      remaining -> raise "Timed out waiting for LISTENING_PORT from Rust binary"
    end
  end
end
