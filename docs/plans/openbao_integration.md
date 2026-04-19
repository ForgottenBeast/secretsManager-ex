# Plan: OpenBao End-to-End Integration Epic

**Status:** Approved (Architect + Critic consensus, 3 iterations)
**Beads feature:** secretmanager-ex-lse.15.1 (under secretmanager-ex-lse.15: Companion: rotating_secrets_vault)
**Epic type:** New companion package + integration test suite
**Date:** 2026-04-18
**Module note:** Integration tests use `RotatingSecrets.Source.Vault.KvV2` per the three-module architecture in `docs/plans/rotating_secrets_vault.md`, not a single `Source.Vault` module.

---

## RALPLAN-DR

### Principles
1. **Zero real credentials** — all test secrets are randomized placeholder values; never real tokens, keys, or passwords
2. **Graceful skip** — `@moduletag :openbao` tests skip cleanly when `bao` binary is absent or `OPENBAO_SKIP=1`; CI is the authoritative gate
3. **Companion-first** — Vault HTTP source lives in `rotating_secrets_vault/` per PRD §5; core package adds no HTTP dep (PRD §11)
4. **KV path isolation** — each test uses a unique path prefix (`test-<ref>/`) under `secret/`; torn down in `on_exit`
5. **Surface-minimal HTTP** — `req ~> 0.5` pinned in companion; no HTTP dep ever enters core

### Decision Drivers
1. OpenBao dev mode: root token `"root"`, `http://127.0.0.1:8200`, in-memory, auto-init, KV v2 at `secret/`
2. KV v2 has no push/watch primitive → `subscribe_changes/1` returns `:not_supported`; Registry polls via `fallback_interval_ms`
3. `custom_metadata.ttl_seconds` (string-encoded integer) is the convention for surfacing TTL hints from KV v2 metadata endpoint
4. Registry `fallback_interval_ms` option (default 60 000 ms) is the test control surface for fast refresh cycles

### Viable Options

**A. Full companion package `rotating_secrets_vault/`** ← chosen
- Separate Mix project; PRD §5-aligned; no HTTP dep in core; production-shippable
- Exercises HTTP-level failure modes (connection refused, 403, request timeout) that a file-shim cannot
- Higher initial effort but correct architectural boundary

**B. Test-only HTTP source in `rotating_secrets/test/support/`**
- Faster scaffolding, but injects `req` into core test env
- Violates PRD §11 ("explicitly not depended on: any HTTP client in core")
- Rejected

**C. File source + file-writing shim (steelman rebuttal)**
- _Steelman:_ The full Registry lifecycle (load, backoff, TTL scheduling, subscriber fan-out, fail-soft) is source-agnostic. A thin test shim that writes files on demand would exercise every lifecycle path without a running OpenBao process, without a new Mix project, without `req`, and without CI timing sensitivity from network round-trips.
- _Why this loses:_ (1) It does not test the HTTP client layer — 403 responses, connection-refused errors, KV v2 response parsing, and TTL extraction from `custom_metadata` are material production risks that a file shim cannot cover. (2) It produces nothing shippable; this epic's goal is to deliver the `rotating_secrets_vault` companion package, not merely to re-verify the Registry. (3) `Source.File` integration tests are already planned in Phase 11 of the core plan; duplication adds no value. Option C covers a different concern (file-watch end-to-end) and is tracked separately.
- Rejected

---

## ADR

**Decision:** Implement `rotating_secrets_vault` as a new companion Mix project providing `RotatingSecretsVault.Source.Vault`, with integration tests in `rotating_secrets_vault/test/integration/` requiring a live OpenBao dev-mode instance.

**Drivers:**
1. PRD §5 explicitly plans the companion structure; this epic delivers it
2. OpenBao's KV v2 API is Vault-compatible; `Source.Vault` works against both
3. Integration tests exercise the full `rotating_secrets` lifecycle against a real secret backend, including HTTP-layer failure modes

**Alternatives considered:** Options B and C above — rejected (see Decision Drivers)

**Consequences:**
- Adds `req` as a runtime dep in `rotating_secrets_vault` only
- `rotating_secrets` core stays dep-free of HTTP (Dialyzer / Credo run independently per project)
- CI gains a new job requiring OpenBao binary; opt-in via `@moduletag :openbao`
- Core `registry.ex` gains two new permanent-error atoms (`:not_found`, `:forbidden`) — one-line change, no API impact

**Follow-ups:**
- AppRole / JWT auth in `Source.Vault` v2 (root token only for dev mode in v1)
- Dynamic secrets (database engine TTL leases) deferred to `Source.Vault` v2
- `rotating_secrets_testing` companion (PRD §5) is a separate epic

---

## Scope

**In scope:**
- Core change: extend `Registry.classify_error/1` with `:not_found` and `:forbidden`
- `rotating_secrets_vault/` companion scaffold (Mix project, deps, formatter, credo)
- `RotatingSecretsVault.Source.Vault` — KV v2 read, version + TTL extraction from metadata
- `OpenBaoHelper` — start/stop `bao server -dev`, poll health, write/delete KV secrets
- `Source.Fault` test helper — wraps any source, enables controlled failure injection for fail-soft tests
- Integration tests: basic read, interval-driven rotation, subscriber notification, fail-soft, TTL metadata
- Unit tests for `Source.Vault` with mocked HTTP (no live server required)
- Property tests for `Source.Vault.init/1` option validation
- CI: `.github/workflows/openbao_integration.yml`
- `mix2nix > mix.nix` after deps changes

**Out of scope:**
- AppRole / JWT / Kubernetes auth methods
- Dynamic secrets (PKI, database engine)
- Vault namespaces / enterprise features
- `Source.File` integration tests (Phase 11 of core plan)
- `rotating_secrets_testing` companion

---

## Phases

### Phase 1 — Core pre-condition: extend `Registry.classify_error/1`

**File:** `rotating_secrets/lib/rotating_secrets/registry.ex` (lines 275–278)

Add `:not_found` and `:forbidden` as permanent errors:

```elixir
defp classify_error(:not_found), do: :permanent_error
defp classify_error(:forbidden), do: :permanent_error
defp classify_error(:enoent), do: :permanent_error
defp classify_error(:eacces), do: :permanent_error
defp classify_error({:invalid_option, _}), do: :permanent_error
defp classify_error(_), do: :transient_error
```

**Rationale:** `:not_found` (wrong path) and `:forbidden` (wrong token/ACL) are misconfiguration errors. They must stop the Registry at initial load time so operators see an immediate, clear error at boot — not a silent backoff loop. On refresh, the error class is still ignored by `handle_info/2` (which calls `schedule_backoff` regardless), so this change only affects initial load behaviour.

**Update `RotatingSecrets.Source` module doc** to list `:not_found` and `:forbidden` as the permanent error atoms a source may return (under the load/1 callback doc).

**Done signal:** `mix test rotating_secrets/test/rotating_secrets/registry_test.exs` passes with the new clauses covered; `mix dialyzer` passes on core.

### Phase 2 — `rotating_secrets_vault` scaffold

**New directory:** `rotating_secrets_vault/`

- `mix new rotating_secrets_vault --module RotatingSecretsVault`
- `mix.exs` runtime deps:
  - `{:rotating_secrets, path: "../rotating_secrets"}`
  - `{:req, "~> 0.5"}`
  - `{:telemetry, "~> 1.0"}`
- Dev/test deps: `{:mox, "~> 1.0", only: :test}`, `{:stream_data, "~> 1.0", only: [:dev, :test]}`
- Tools: `{:ex_doc, "~> 0.34", only: :dev, runtime: false}`, `{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}`, `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}`
- `.formatter.exs`, `.credo.exs` (strict baseline matching core)
- `config/test.exs`: `config :logger, level: :warning` — prevents `req` debug logs (which may contain Authorization header) from appearing in CaptureLog assertions
- `mix deps.get && mix2nix > mix.nix`
- `br init` for beads tracker

**Done signal:** `cd rotating_secrets_vault && mix compile` exits 0; `mix credo --strict` passes on the empty scaffold.

### Phase 3 — `RotatingSecretsVault.Source.Vault`

**`rotating_secrets_vault/lib/rotating_secrets_vault/source/vault.ex`**

```
@behaviour RotatingSecrets.Source

init(opts) →
  required: :address (binary URL), :token (binary), :path (binary)
  optional: :mount (binary, default "secret")
  optional: :key (binary, default "value") — field name within KV data map
  optional: :req_options (keyword) — merged into Req client opts
  build a %Req.Request{} base client with base_url, Authorization header, json: true
  {:ok, %{mount, path, key, client}}

load(state) →
  # 1. Fetch secret data
  GET /v1/{mount}/data/{path}
  200 → extract body["data"]["data"][state.key] → value (must be binary)
        → if not binary: {:error, {:invalid_value, actual_type}, state}
  404 → {:error, :not_found, state}
  403 → {:error, :forbidden, state}
  other HTTP status → {:error, {:http_error, status, body["errors"]}, state}
  Req exception (ECONNREFUSED etc.) → {:error, {:connection_error, reason}, state}

  # 2. Fetch metadata for TTL hint (best-effort; failure is non-fatal)
  GET /v1/{mount}/metadata/{path}
  200 → parse custom_metadata["ttl_seconds"] as integer via Integer.parse/1
  any failure (404, 403, exception) → ttl_seconds = nil

  # 3. Build meta map
  version = get_in(data_body, ["data", "metadata", "version"])   # integer from KV v2
  issued_at = parse_iso8601(get_in(data_body, ["data", "metadata", "created_time"]))
  meta = %{version: version, issued_at: issued_at, ttl_seconds: ttl}

  {:ok, value, meta, state}

subscribe_changes(_state) → :not_supported
# KV v2 has no push primitive; Registry polls via fallback_interval_ms
```

**Security requirements:**
- `Source.Vault` MUST NOT log the token at any level
- `init/1` must not include the token in any error tuple (use a sanitised map)
- The `req` client Authorization header is built in `init/1` and stored in state (sensitive, under the Registry's `:sensitive` flag process)
- `config :logger, level: :warning` in `config/test.exs` suppresses req debug logs in tests

**Done signal:** `mix dialyzer` and `mix credo --strict` pass; unit tests (Phase 10) pass without live server.

### Phase 4 — OpenBao test infrastructure

**`rotating_secrets_vault/test/support/openbao_helper.ex`**

```elixir
defmodule OpenBaoHelper do
  @base_url "http://127.0.0.1:8200"
  @root_token "root"

  def start_server!() do
    bin = System.find_executable("bao") ||
          System.get_env("OPENBAO_BIN") ||
          raise "bao binary not found — set OPENBAO_BIN or add bao to PATH"
    port = Port.open({:spawn_executable, bin},
                     [:binary, :exit_status,
                      args: ["server", "-dev",
                             "-dev-root-token-id=root",
                             "-dev-listen-address=127.0.0.1:8200"]])
    wait_for_health!()
    port
  end

  def stop_server!(port), do: Port.close(port)

  # Poll GET /v1/sys/health until 200 or timeout (10s)
  # Req.get may raise on ECONNREFUSED during startup — rescue to treat as not-yet-ready
  def wait_for_health!(attempts \\ 100) do
    ready =
      try do
        case Req.get("#{@base_url}/v1/sys/health") do
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
        wait_for_health!(attempts - 1)
      else
        raise "OpenBao did not become healthy within 10 seconds"
      end
    end
  end

  def write_secret!(mount, path, data, custom_metadata \\ %{}) do
    client = build_client()
    Req.post!(client, url: "/v1/#{mount}/data/#{path}",
              json: %{"data" => data})
    unless map_size(custom_metadata) == 0 do
      Req.post!(client, url: "/v1/#{mount}/metadata/#{path}",
                json: %{"custom_metadata" => custom_metadata})
    end
    :ok
  end

  # Deletes all versions + metadata for a KV path
  def delete_path!(mount, path) do
    client = build_client()
    Req.delete!(client, url: "/v1/#{mount}/metadata/#{path}")
    :ok
  end

  def base_url, do: @base_url
  def root_token, do: @root_token

  defp build_client do
    Req.new(base_url: @base_url,
            headers: [{"X-Vault-Token", @root_token}])
  end
end
```

**`rotating_secrets_vault/test/support/source_fault.ex`**

A controllable source wrapper for fail-soft tests. Wraps any `Source` behaviour implementation and can be instructed to start returning a configurable error from `load/1`:

```elixir
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
    fault_name = Keyword.fetch!(opts, :fault_name)  # atom, used to look up fault state

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
```

**`rotating_secrets_vault/test/test_helper.exs`**

```elixir
Code.require_file("support/openbao_helper.ex", __DIR__)
Code.require_file("support/source_fault.ex", __DIR__)

openbao_available =
  System.get_env("OPENBAO_SKIP") != "1" and
  (System.find_executable("bao") != nil or System.get_env("OPENBAO_BIN") != nil)

if openbao_available do
  port = OpenBaoHelper.start_server!()
  Application.put_env(:rotating_secrets_vault_test, :openbao_port, port)
  # ExUnit.after_suite/1 runs within the test lifecycle — guaranteed to execute
  # even on suite failure; unlike System.at_exit which may not run if the VM
  # is killed or the port owner has already exited.
  ExUnit.after_suite(fn _result ->
    case Application.get_env(:rotating_secrets_vault_test, :openbao_port) do
      nil -> :ok
      p -> OpenBaoHelper.stop_server!(p)
    end
  end)
else
  ExUnit.configure(exclude: [:openbao])
  IO.puts("[OpenBaoHelper] bao binary not found or OPENBAO_SKIP=1 — :openbao tests excluded")
end

ExUnit.start()
```

**Per-test path isolation pattern** (used in every integration test):

```elixir
setup do
  prefix = "test-#{:erlang.unique_integer([:positive])}"
  on_exit(fn -> OpenBaoHelper.delete_path!("secret", prefix) end)
  {:ok, prefix: prefix}
end
```

### Phase 5 — Basic read integration tests

**`rotating_secrets_vault/test/integration/openbao/basic_test.exs`**

`use ExUnit.Case, async: false` — see Notes on async.

Tests (`@moduletag :openbao`):

1. **`reads secret value from OpenBao KV v2`**
   - `OpenBaoHelper.write_secret!("secret", "#{prefix}/api_key", %{"value" => "my-secret-abc"})`
   - `RotatingSecrets.register(:api_key, source: RotatingSecretsVault.Source.Vault, source_opts: [address: OpenBaoHelper.base_url(), token: OpenBaoHelper.root_token(), path: "#{prefix}/api_key"])`
   - `{:ok, secret} = RotatingSecrets.current(:api_key)`
   - Assert `RotatingSecrets.Secret.expose(secret) == "my-secret-abc"`
   - `RotatingSecrets.deregister(:api_key)` in on_exit

2. **`initial load failure stops the Registry — path does not exist`**
   - Attempt register with path `"#{prefix}/nonexistent"`
   - Assert result is `{:error, _}` (permanent load failure, Registry never starts)

3. **`returns KV v2 version in meta`**
   - Write secret; register; `{:ok, s} = current/1`; assert `RotatingSecrets.Secret.meta(s).version == 1`

4. **`with_secret/2 executes with correct value`**
   - Write secret; `RotatingSecrets.with_secret(:name, fn s -> RotatingSecrets.Secret.expose(s) end)`
   - Assert `{:ok, "expected-value"}`

5. **`secret value not logged during load`**
   - `ExUnit.CaptureLog` wraps register + current
   - Assert log output does not contain the secret value string
   - Note: `config :logger, level: :warning` in `config/test.exs` ensures req debug logs (which could include Authorization headers) are suppressed; this test only checks application-level logs at warning+

### Phase 6 — Rotation integration tests

**`rotating_secrets_vault/test/integration/openbao/rotation_test.exs`**

`use ExUnit.Case, async: false`

Tests (`@moduletag :openbao`):

1. **`picks up new value after interval refresh`**
   - Write `%{"value" => "v1"}` to KV
   - Register with `source_opts: [..., fallback_interval_ms: 300]`
   - Assert `current/1` returns `"v1"`
   - `OpenBaoHelper.write_secret!("secret", path, %{"value" => "v2"})`
   - Wait for `[:rotating_secrets, :rotation]` telemetry event via `assert_receive` with 2000ms timeout
   - Assert `current/1` returns `"v2"` (use event-driven wait, not fixed sleep)

2. **`KV version increments in meta after rotation`**
   - Write v1; register; assert `meta.version == 1`
   - Update KV (write v2)
   - Wait for rotation event; assert `meta.version == 2`

3. **`telemetry :rotation event fires with correct metadata, no secret value`**
   - Attach handler for `[:rotating_secrets, :rotation]`; store event in process mailbox
   - Trigger rotation (write new KV value, wait for refresh)
   - Assert event received with `:name` atom and `:version_new` integer
   - Assert the event measurement/metadata map does NOT contain any key with the secret value as value
   - Assert the serialized `inspect(event_map)` does not contain the secret string

4. **`telemetry :source_load_stop fires on each refresh`**
   - Attach handler for `[:rotating_secrets, :source, :load, :stop]`
   - Wait for one refresh cycle; assert event fired with `%{name: _, duration_ms: _}`

### Phase 7 — Subscriber integration tests

**`rotating_secrets_vault/test/integration/openbao/subscriber_test.exs`**

`use ExUnit.Case, async: false`

Tests (`@moduletag :openbao`):

1. **`subscriber receives notification after KV rotation`**
   - Register with `fallback_interval_ms: 300`
   - `{:ok, ref} = RotatingSecrets.subscribe(:name)`
   - `OpenBaoHelper.write_secret!("secret", path, %{"value" => "new-val"})`
   - `assert_receive {:rotating_secret_rotated, ^ref, :name, _version}, 2000`

2. **`notification message contains no secret value`**
   - Capture the `{:rotating_secret_rotated, ref, name, version}` message
   - Assert it is a 4-tuple; assert `version` is an integer (from KV v2 metadata)
   - Assert `inspect({:rotating_secret_rotated, ref, name, version})` does not contain the secret string

3. **`subscriber auto-removed on process exit`**
   - `Task.start(fn -> RotatingSecrets.subscribe(:name) end)` — subscribe from a dying process
   - Wait for `[:rotating_secrets, :subscriber_removed]` telemetry
   - Trigger rotation; assert no `:noproc` errors logged; assert Registry PID still alive

4. **`unsubscribe stops notifications`**
   - Subscribe; `RotatingSecrets.unsubscribe(ref)`; trigger rotation
   - `refute_receive {:rotating_secret_rotated, ^ref, _, _}, 2000`

### Phase 8 — Fail-soft integration tests

**`rotating_secrets_vault/test/integration/openbao/fail_soft_test.exs`**

`use ExUnit.Case, async: false`

**Test 1 — `serves last-known-good when source becomes unreachable`**

Uses `SourceFault` to inject controlled connection-refused errors after initial load:

```elixir
test "serves last-known-good when source becomes unreachable", %{prefix: prefix} do
  write_secret!(prefix, "api_key", "initial-value")

  fault_name = :"fault_#{:erlang.unique_integer([:positive])}"

  # Register via SourceFault wrapper
  {:ok, _} = RotatingSecrets.register(:fault_secret,
    source: SourceFault,
    source_opts: [
      source: RotatingSecretsVault.Source.Vault,
      source_opts: [address: base_url(), token: root_token(), path: "#{prefix}/api_key"],
      fault_name: fault_name,
      fallback_interval_ms: 300
    ]
  )

  # Initial load succeeds
  {:ok, s1} = RotatingSecrets.current(:fault_secret)
  assert Secret.expose(s1) == "initial-value"

  # Attach handler before arming to avoid race between arm! and first failed load event
  attach_telemetry_handler(:source_load_stop_test, [:rotating_secrets, :source, :load, :stop])

  # Arm the fault — subsequent loads return {:error, {:connection_error, :econnrefused}, state}
  SourceFault.arm!(fault_name)
  assert_receive {:telemetry_event, [:rotating_secrets, :source, :load, :stop], _, _}, 2000

  # Registry still serves last-known-good
  {:ok, s2} = RotatingSecrets.current(:fault_secret)
  assert Secret.expose(s2) == "initial-value"

  # Registry PID is still alive
  assert Process.alive?(GenServer.whereis(:fault_secret))
end
```

**Test 2 — `Registry stays alive through persistent HTTP 404 (path deleted)`**

Models the scenario where a KV path is deleted after the Registry has started:

```elixir
test "Registry stays alive and serves stale when KV path deleted", %{prefix: prefix} do
  write_secret!(prefix, "key", "loaded-value")
  {:ok, _} = RotatingSecrets.register(:stale_secret, ...)  # fallback_interval_ms: 300

  {:ok, s} = RotatingSecrets.current(:stale_secret)
  assert Secret.expose(s) == "loaded-value"

  # Delete the secret from OpenBao (simulates path removal mid-operation)
  OpenBaoHelper.delete_path!("secret", "#{prefix}/key")

  # Wait for a refresh attempt; :not_found is classified permanent in classify_error
  # but handle_info ignores the class and calls schedule_backoff — Registry stays alive
  attach_telemetry_handler(:load_stop, [:rotating_secrets, :source, :load, :stop])
  assert_receive {:telemetry_event, [:rotating_secrets, :source, :load, :stop], _, _}, 2000

  # Stale value still served
  {:ok, s2} = RotatingSecrets.current(:stale_secret)
  assert Secret.expose(s2) == "loaded-value"
  assert Process.alive?(GenServer.whereis(:stale_secret))
end
```

**Test 3 — `exponential backoff increases delay between retries`**

```elixir
test "exponential backoff increases interval between load attempts", %{prefix: prefix} do
  fault_name = :"backoff_fault_#{:erlang.unique_integer([:positive])}"
  write_secret!(prefix, "k", "v")
  # Register via SourceFault with min_backoff_ms: 50
  {:ok, _} = RotatingSecrets.register(:backoff_secret, ...)

  {:ok, _} = RotatingSecrets.current(:backoff_secret)
  SourceFault.arm!(fault_name)

  # Collect timestamps of load stop events (3 events)
  attach_telemetry_handler(:backoff_events, [:rotating_secrets, :source, :load, :stop])
  t0 = System.monotonic_time(:millisecond)
  assert_receive {:telemetry_event, _, _, _}, 500
  t1 = System.monotonic_time(:millisecond)
  assert_receive {:telemetry_event, _, _, _}, 1000
  t2 = System.monotonic_time(:millisecond)
  assert_receive {:telemetry_event, _, _, _}, 2000
  t3 = System.monotonic_time(:millisecond)

  # Intervals should grow: (t2-t1) > (t1-t0) and (t3-t2) > (t2-t1)
  assert (t2 - t1) > (t1 - t0)
  assert (t3 - t2) > (t2 - t1)
end
```

### Phase 9 — TTL metadata integration tests

**`rotating_secrets_vault/test/integration/openbao/ttl_test.exs`**

`use ExUnit.Case, async: false`

Tests (`@moduletag :openbao`):

1. **`respects ttl_seconds from KV v2 custom_metadata`**
   - Write secret with `custom_metadata: %{"ttl_seconds" => "1"}` (1 second TTL)
   - Register with NO explicit `fallback_interval_ms` (TTL from metadata drives scheduling)
   - Source reads `custom_metadata.ttl_seconds = 1` → `meta.ttl_seconds = 1`
   - Registry schedules refresh at `trunc(1000 * 2/3) = 666ms`
   - Update KV value in OpenBao at 500ms mark
   - Wait for `[:rotating_secrets, :rotation]` event via `assert_receive 2000`
   - Assert new value is visible (event-driven, no fixed sleep — avoids CI timing flakiness)

2. **`falls back to fallback_interval_ms when no custom_metadata TTL`**
   - Write secret without custom_metadata
   - Register with `fallback_interval_ms: 300`
   - Update KV value; wait for rotation event via `assert_receive 2000`; assert new value picked up

3. **`version from KV v2 metadata drives monotone versioning`**
   - Write 3 versions sequentially (write v1, wait for rotation event, write v2, wait, write v3, wait)
   - Collect `meta.version` after each rotation event
   - Assert sequence is strictly increasing: `[1, 2, 3]`

### Phase 10 — Unit tests for `Source.Vault` (no live server)

**`rotating_secrets_vault/test/rotating_secrets_vault/source/vault_test.exs`**

Using `Req.Test` (ships with `req ~> 0.5`; available since req 0.4.0):

- 200 response → correct extraction of `value`, `version`, `issued_at`
- 200 response with `custom_metadata.ttl_seconds "30"` → `meta.ttl_seconds == 30`
- 200 response with missing metadata endpoint (404) → `meta.ttl_seconds == nil`; load still succeeds
- 404 on data endpoint → `{:error, :not_found, state}`
- 403 on data endpoint → `{:error, :forbidden, state}`
- Non-binary value in KV data (e.g., integer) → `{:error, {:invalid_value, :integer}, state}`
- Connection error (ECONNREFUSED equivalent) → `{:error, {:connection_error, _}, state}`
- `init/1` with missing `:path` → `{:error, _}`; error tuple must not contain the token
- Token never in any `{:error, _, _}` tuple: assert `inspect(error_result)` does not contain the token string
- Logger level set to `:debug` for this test file only (override config) to ensure even debug-level logs do not contain the token string — use `ExUnit.CaptureLog` with `capture_log(level: :debug, fn -> ... end)` form

### Phase 11 — Property tests for `Source.Vault.init/1`

**`rotating_secrets_vault/test/rotating_secrets_vault/source/vault_properties_test.exs`**

Using `StreamData`:

```elixir
property "init/1 never returns {:ok, state} with invalid required opts" do
  check all opts <- StreamData.list_of(StreamData.tuple({StreamData.atom(:alphanumeric), StreamData.term()})) do
    result = RotatingSecretsVault.Source.Vault.init(opts)
    # If :address, :token, :path are all missing or wrong type,
    # init must return {:error, _} without raising
    if not has_required_string_opts?(opts) do
      assert match?({:error, _}, result)
    end
  end
end

property "init/1 never includes :token value in error reason" do
  check all token <- StreamData.binary(min_length: 1),
            opts <- StreamData.list_of(StreamData.tuple({StreamData.atom(:alphanumeric), StreamData.term()})) do
    opts_with_token = Keyword.put(opts, :token, token)
    case RotatingSecretsVault.Source.Vault.init(opts_with_token) do
      {:error, reason} -> refute inspect(reason) =~ token
      {:ok, _} -> :ok
    end
  end
end
```

**Done signal:** `mix test test/rotating_secrets_vault/source/vault_properties_test.exs` passes with 100+ generated cases.

### Phase 12 — CI integration

**`.github/workflows/openbao_integration.yml`**

```yaml
name: OpenBao Integration Tests
on: [push, pull_request]
jobs:
  openbao-integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Kill any existing bao processes (port conflict guard)
        run: pkill bao || true

      - name: Install OpenBao
        run: |
          # Verify the exact asset filename at https://github.com/openbao/openbao/releases
          # before changing BAO_VERSION — asset naming changes between releases.
          BAO_VERSION=2.2.0
          curl -fsSL \
            "https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}/bao_${BAO_VERSION}_linux_amd64.zip" \
            -o bao.zip
          unzip bao.zip bao -d /usr/local/bin/
          chmod +x /usr/local/bin/bao
          bao version

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.18'
          otp-version: '27'

      - name: Cache deps
        uses: actions/cache@v4
        with:
          path: |
            rotating_secrets/deps
            rotating_secrets_vault/deps
          key: ${{ runner.os }}-openbao-deps-${{ hashFiles('rotating_secrets_vault/mix.lock') }}

      - name: Install deps
        run: |
          cd rotating_secrets && mix deps.get
          cd ../rotating_secrets_vault && mix deps.get

      - name: Run unit tests (no live server)
        run: cd rotating_secrets_vault && mix test

      - name: Run OpenBao integration tests
        run: cd rotating_secrets_vault && mix test --only openbao
        env:
          MIX_ENV: test
```

---

## Test file layout

```
rotating_secrets_vault/
├── lib/
│   └── rotating_secrets_vault/
│       └── source/
│           └── vault.ex
├── test/
│   ├── support/
│   │   ├── openbao_helper.ex
│   │   └── source_fault.ex
│   ├── test_helper.exs
│   ├── rotating_secrets_vault/
│   │   └── source/
│   │       ├── vault_test.exs                 (unit, no server required)
│   │       └── vault_properties_test.exs      (StreamData property tests)
│   └── integration/
│       └── openbao/
│           ├── basic_test.exs                 @moduletag :openbao
│           ├── rotation_test.exs              @moduletag :openbao
│           ├── subscriber_test.exs            @moduletag :openbao
│           ├── fail_soft_test.exs             @moduletag :openbao
│           └── ttl_test.exs                   @moduletag :openbao
├── config/
│   └── test.exs                               config :logger, level: :warning
└── mix.exs
```

---

## Notes for executor

- **`async: false` rationale:** Integration tests use `fallback_interval_ms: 300` and `assert_receive` with 2000ms timeouts. Concurrent tests under CI scheduler pressure can introduce enough BEAM scheduler jitter to cause spurious `assert_receive` timeouts. `async: false` is a timing-conservatism decision, not a correctness requirement — KV path isolation via unique prefixes is sufficient to prevent data collisions. Follow-up: enable `async: true` for basic_test.exs (no timing dependencies) and ttl_test.exs (event-driven only) once the suite has proven stable in CI.
- **Event-driven vs. sleep-based rotation waits:** All rotation waits use `assert_receive {:telemetry_event, [:rotating_secrets, :rotation], ...}, 2000` rather than `Process.sleep`. This eliminates CI timing flakiness for rotation tests. Attach telemetry handlers in `setup` and detach in `on_exit` using `telemetry_handler_id = "test-#{inspect(self())}"` as the handler ID.
- **`classify_error/1` core change (Phase 1) must be committed before Phase 3 tests pass.** On initial load, `:not_found` and `:forbidden` must produce `{:stop, {:permanent_load_failure, _}}`. On refresh, the error class is ignored by `handle_info/2` (lines 164–167 of registry.ex call `schedule_backoff` regardless of class) — so the Phase 8 fail-soft tests are coherent even after the fix.
- **`SourceFault` and OpenBao at the same time:** The fail-soft tests in Phase 8 use `SourceFault` wrapping `Source.Vault` pointed at the real OpenBao. Tests that need "source becomes unreachable" use `SourceFault.arm!/1`. Tests that need "KV path deleted" use `OpenBaoHelper.delete_path!/2` directly against OpenBao.
- **OpenBao binary version pinning:** Verify the exact release asset filename format at `https://github.com/openbao/openbao/releases` before the CI step is committed. The zip may contain the binary at a different path in future releases.
- **`bao server -dev` port conflicts:** If port 8200 is already in use on the CI host, `wait_for_health!` will time out. The CI step should kill any running `bao` processes before starting (`pkill bao || true`) as a defensive step.
- **After Phase 2 deps change:** `mix deps.get && mix2nix > mix.nix && git add mix.nix`
- **Telemetry handler helper pattern** (for rotation event assertions):
  ```elixir
  defp attach_telemetry_handler(id, event) do
    test_pid = self()
    :telemetry.attach(
      "#{id}-#{inspect(test_pid)}",
      event,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )
    on_exit(fn -> :telemetry.detach("#{id}-#{inspect(test_pid)}") end)
  end
  ```
- **`Source.Vault` token never in error tuples:** `init/1` should use `Keyword.fetch!` and if a required key is missing, return `{:error, {:missing_option, :key_name}}` — never include the token value even in a "wrong type" error.
- **Logger backend assumption:** The `config :logger, level: :warning` in `config/test.exs` suppresses req debug logs that may contain Authorization header values. The no-token CaptureLog assertion in Phase 10 unit tests uses `capture_log(level: :debug, fn -> ... end)` to explicitly check even debug-level output.

---

## Acceptance Criteria

- [ ] Core `registry.ex` has `:not_found` and `:forbidden` classified as permanent errors; `mix test` on core passes
- [ ] `rotating_secrets_vault/` is a standalone Mix project with correct deps and `mix.nix`
- [ ] `Source.Vault` implements all 5 `RotatingSecrets.Source` callbacks; passes `mix dialyzer` and `mix credo --strict`
- [ ] `mix test` (unit + property tests, no `:openbao` tag) passes without a live OpenBao instance
- [ ] `mix test --only openbao` passes against a live OpenBao dev-mode instance
- [ ] Tests skip gracefully with `OPENBAO_SKIP=1` or absent `bao` binary; informative message printed
- [ ] Basic read: `current/1` returns correct value loaded from OpenBao KV v2 (Phase 5 test 1)
- [ ] Initial load failure: Registry stops immediately for missing path (Phase 5 test 2)
- [ ] Rotation: updated KV value picked up after `fallback_interval_ms`; verified via telemetry event, not sleep (Phase 6)
- [ ] Subscriber: `{:rotating_secret_rotated, ref, name, version}` received after rotation; message confirmed as 4-tuple with no secret value (Phase 7)
- [ ] Fail-soft via SourceFault: Registry alive after connection errors; last-known-good served (Phase 8 test 1)
- [ ] Fail-soft via deleted path: Registry alive after KV 404 on refresh; stale value served (Phase 8 test 2)
- [ ] Exponential backoff: inter-retry intervals grow after consecutive failures (Phase 8 test 3)
- [ ] TTL metadata: `custom_metadata.ttl_seconds` drives 2/3-lifetime refresh; verified via rotation event (Phase 9)
- [ ] `[:rotating_secrets, :rotation]` telemetry fires with `:name`, `:version_new`; `inspect(metadata)` does not contain secret value (Phase 6 test 3)
- [ ] Token never in any `{:error, _, _}` tuple; `inspect(error)` does not contain token string (Phase 10 unit test)
- [ ] Property tests: `init/1` never raises on arbitrary opts; error tuples never contain token value (Phase 11)
- [ ] CI GitHub Actions job runs both unit and integration suites with pinned OpenBao binary (Phase 12)
- [ ] `mix2nix > mix.nix` committed after deps are finalized
