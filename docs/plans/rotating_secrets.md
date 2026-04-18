# Plan: rotating_secrets — Elixir Secret Lifecycle Library

**Status:** Approved
**Owner:** Quentin Mallet
**PRD:** `prd`
**Date:** 2026-04-18

---

## ADR

**Decision:** Implement `rotating_secrets` as a standalone Elixir library with one GenServer per secret (no ETS fast-path in v1), opaque `%Secret{}` struct, pluggable `Source` behaviour, and borrow/push API.

**Drivers:**
1. BEAM isolation + `:sensitive` flag requires one process per secret
2. Elixir immutability makes borrow semantics trivial (struct handle)
3. Vault Agent atomic rename is the primary production deployment path

**Alternatives considered:**
- ETS read-through cache: explicitly rejected per PRD §7.3; deferred to v2
- `:persistent_term` fast-path: same deferral; global GC pauses on rotation make it unsuitable for v1

**Consequences:** Throughput ceiling ~200k ops/s theoretical; 50k ops/s target is gated by benchee in Phase 13. v2 can add ETS write-on-rotation without public API changes.

**Follow-ups:** Monitor production read latency; if bottleneck materializes, add ETS hook in v2.

---

## RALPLAN-DR

**Principles**
1. Security-first: no code path exposes secret values in logs, telemetry, crash dumps, or mailboxes
2. Fail-soft after initial success: serve last-known-good; never crash consumers on rotation error
3. Minimal core deps: `telemetry` mandatory runtime; `file_system` optional
4. Behaviour extensibility: one callback module per source; consumers are source-agnostic
5. Opinionated defaults with escape hatches

**Decision Drivers**
1. BEAM process model: one GenServer per secret gives isolation + `:sensitive` flag per process
2. Immutable data: borrow semantics = struct handle, no locking needed
3. Vault Agent atomic rename is the production path: file source must watch parent directory

**ETS fast-path — REJECTED for v1**
PRD §7.3 explicitly states reads are serialized through the Registry GenServer as a deliberate choice over ETS. `:persistent_term` fast-path deferred to v2.

**Ash Framework — NOT applicable**
`rotating_secrets` is a standalone open-source library. No Phoenix, Ash, or HTTP dependency (PRD §3). Ash rules in project AGENTS.md apply to application code wrapping the library, not the library itself.

---

## Phases

### Phase 0 — Scaffold

- `mix new rotating_secrets --module RotatingSecrets`
- `mix.exs` runtime deps: `telemetry`, `file_system` (`optional: true`)
- `mix.exs` dev/test deps: `stream_data ~> 1.0`, `mox`, `local_cluster`, `ex_doc`, `dialyxir`, `credo`, `benchee`, `snabbkaffe ~> 1.0`, `observlib` (github, dev/test — for telemetry handler setup in tests)
- `.credo.exs` (strict baseline), `.formatter.exs`
- CI: GitHub Actions with dialyzer PLT caching
- `br init` — beads tracker (global AGENTS.md requirement)
- Export this plan to `docs/plans/rotating_secrets.md`
- `mix deps.get && mix2nix > mix.nix`

### Phase 1 — TLA+ Specification

File: `specs/registry.tla`

- States: `Loading`, `Valid`, `Refreshing`, `Expiring`, `Expired`
- Transitions with pre/postconditions
- Invariants:
  - `TypeInvariant`: state always one of the five
  - `NoNilAfterLoad`: after initial load succeeds, `current_value ≠ nil` forever
  - `MonotoneVersions`: readers observe non-decreasing version sequences
- Liveness: a valid source eventually reaches `Valid`
- Run TLC; capture results in `specs/README.md`

### Phase 2 — Core Data Structures

**`lib/rotating_secrets/secret.ex`**
- `@opaque t :: %__MODULE__{name: atom(), value: binary(), meta: map()}`
- `expose/1`, `meta/1`, `name/1`
- `defimpl Inspect` → `"#RotatingSecrets.Secret<#{n}:redacted>"` (uses the `name` field)
- `defimpl String.Chars` → raises `ArgumentError`
- `defimpl Jason.Encoder` → raises `ArgumentError` (NOT `@derive {Jason.Encoder, only: []}` — that silently produces `{}`)
- Conditional `Phoenix.Param` defimpl: generated only when `Code.ensure_loaded?(Phoenix.Param)` is true at compile time; raises with a clear message directing callers to `expose/1`

**`lib/rotating_secrets/source.ex`** — behaviour:
- `@callback init(opts :: keyword()) :: {:ok, state} | {:error, term()}`
- `@callback load(state) :: {:ok, material, meta, state} | {:error, term(), state}`
- `@callback subscribe_changes(state) :: {:ok, ref :: term(), state} | :not_supported`
- `@callback handle_change_notification(msg :: term(), state) :: {:changed, state} | :ignored | {:error, term()}`
- `@callback terminate(state) :: :ok`

Message dispatch contract: sources that return `{:ok, ref, state}` from `subscribe_changes/1` MUST ensure subscription messages sent to the Registry are identifiable via that `ref`. The Registry stores the ref in state and delegates all unrecognized `handle_info` messages to `Source.handle_change_notification/2`.

### Phase 3 — Registry GenServer

**`lib/rotating_secrets/registry.ex`**

State machine: `:loading → :valid → :refreshing → :valid / :expiring → :expired`

- `init/1`: `Process.flag(:sensitive, true)` first; call `source.init(opts)` (fast, no I/O); return `{:ok, state, {:continue, :initial_load}}`
- `handle_continue(:initial_load)`:
  - Call `source.load(source_state)`
  - Permanent errors (`:enoent`, `:eacces`, config invalid) → `{:stop, {:permanent_load_failure, reason}, state}`
  - Transient errors → `{:stop, {:transient_load_failure, reason}, state}`
  - Success → transition `:valid`, schedule refresh, `{:noreply, state}`
- `handle_call(:current)` → `{:reply, {:ok, state.secret}, state}` — no I/O, memory only
- `handle_call({:subscribe, pid})` → `Process.monitor(pid)`, add to subscribers map
- `handle_call({:unsubscribe, ref})` → remove from subscribers
- `handle_info(:do_refresh)` → `source.load`, update state, emit telemetry, fan out name-and-version notifications to subscribers: `{:rotating_secret_rotated, sub_ref, name, version}`
- `handle_info({:DOWN, monitor_ref, :process, _, _})` → remove dead subscriber, emit `:subscriber_removed`
- `handle_info(msg)` → delegate to `Source.handle_change_notification(msg, source_state)`:
  - `{:changed, new_source_state}` → trigger refresh
  - `:ignored` → noreply
  - `{:error, reason}` → log with structured metadata, noreply
- `terminate/2` → `Source.terminate(source_state)`

Refresh scheduling:
- TTL present: `Process.send_after(self(), :do_refresh, trunc(ttl_ms * 2/3))`
- No TTL: use configured fallback interval
- On error: exponential backoff, min 1s (configurable), capped 60s (configurable)

Registry must accept `registry_via` option so processes can be started under `{:via, Horde.Registry, ...}` without a hard Horde dependency. `child_spec` must be fully serializable (no closures, no PIDs, no refs) for Horde migration compatibility.

### Phase 4 — Telemetry Module

**`lib/rotating_secrets/telemetry.ex`**
- Module attributes for all `[:rotating_secrets, ...]` event names from PRD §7.5:
  - `[:rotating_secrets, :source, :load, :start]`
  - `[:rotating_secrets, :source, :load, :stop]`
  - `[:rotating_secrets, :source, :load, :exception]`
  - `[:rotating_secrets, :rotation]`
  - `[:rotating_secrets, :state_change]`
  - `[:rotating_secrets, :subscriber_added]`
  - `[:rotating_secrets, :subscriber_removed]`
  - `[:rotating_secrets, :degraded]`
  - `[:rotating_secrets, :dev_source_in_use]` (PRD §8.2)
- Private `emit_*` helpers — each validates no secret value in metadata
- `attach_default_handlers/0` for consuming apps

Note: library emits raw `:telemetry.execute/3` (correct for open-source library). The consuming application calls `Observlib.setup/1`. In this repo's test suite, `test/test_helper.exs` calls `Observlib.setup/1` so telemetry assertions work through the observlib pipeline.

### Phase 5 — Supervisor

**`lib/rotating_secrets/supervisor.ex`**
- `DynamicSupervisor` as parent
- Each Registry child: restart `:transient`, default name via `{:via, Registry, {RotatingSecrets.ProcessRegistry, name}}`; overridable via `registry_via:` option (PRD §6.5; supports Horde)
- DynamicSupervisor: `max_restarts: 3, max_seconds: 30` — after 3 failures in 30s, supervisor stops and error surfaces to application (boot-time failure detection)
- `RotatingSecrets.register(name, opts)` → `DynamicSupervisor.start_child/2`
- `RotatingSecrets.deregister(name)` → `DynamicSupervisor.terminate_child/2`
- `registry_via` option propagated to each Registry child_spec

### Phase 6 — Public API

**`lib/rotating_secrets.ex`**

```elixir
@spec current(name :: atom()) :: {:ok, Secret.t()} | {:error, term()}
@spec current!(name :: atom()) :: Secret.t()
@spec with_secret(name :: atom(), (Secret.t() -> result)) :: {:ok, result} | {:error, term()}
    when result: var
@spec subscribe(name :: atom()) :: {:ok, reference()} | {:error, term()}
@spec unsubscribe(reference()) :: :ok
@spec register(name :: atom(), opts :: keyword()) :: {:ok, pid()} | {:error, term()}
@spec deregister(name :: atom()) :: :ok
@spec cluster_status(name :: atom()) ::
    %{node() => {:ok, version :: term(), meta :: map()} | {:error, term()}}
```

`subscribe/1` delivers `{:rotating_secret_rotated, reference(), name, version}` messages on rotation only (not on subscription); subscribers call `current/1` explicitly after subscribing.

### Phase 7 — File Source

**`lib/rotating_secrets/source/file.ex`**

- `init/1`: validate path; check file permissions — warn (not crash) if group/world-readable (PRD §8.1)
- `load/1`: `File.read!(path)` → `String.trim_trailing/1`
- `:file_watch` mode:
  - `subscribe_changes/1`: start `FileSystem` watcher on **parent directory** (not the file path itself — required to receive `moved_to` events from atomic rename)
  - `handle_change_notification({:file_event, _pid, {path, events}}, state)`: match on `Path.basename(path) == target_filename and (:modified in events or :moved_to in events)`
  - `terminate/1`: stop the `FileSystem` watcher
- `{:interval, ms}` mode: `subscribe_changes/1` returns `:not_supported`; Registry polls via `send_after`
- Missing file on initial load = error. Missing file on refresh = serve stale, log, continue retrying.

### Phase 8 — Env Source

**`lib/rotating_secrets/source/env.ex`**
- `init/1`: emit `[:rotating_secrets, :dev_source_in_use]` telemetry; `Logger.warning/2` with structured metadata
- `load/1`: `System.fetch_env(var_name)` → `{:error, :not_set}` (no raise)
- `subscribe_changes/1`: `:not_supported`

### Phase 9 — Memory Source

**`lib/rotating_secrets/source/memory.ex`**

`Source.Memory` holds its current value in its own source state (no separate GenServer required). The subscription mechanism uses the dispatch contract established in Phase 2.

- `init/1`: store initial binary value; store `registry_pid` (resolved by name) for push notification
- `load/1`: return current value from source state
- `subscribe_changes/1`: returns `{:ok, channel_ref, %{state | channel_ref: channel_ref}}` where `channel_ref = make_ref()`; the Registry stores this ref
- `handle_change_notification({channel_ref, :updated}, state)` where `channel_ref` matches `state.channel_ref`: return `{:changed, %{state | value: state.pending_value}}`
- `update/2` (public API): stores the new value in a pending field in source state, then calls `send(registry_pid, {channel_ref, :updated})`; the Registry's catch-all `handle_info` delegates this to `handle_change_notification/2` → `{:changed, new_source_state}` → refresh

**Critical:** `update/2` sends `{channel_ref, :updated}` to the Registry PID — a message tagged with the subscription ref. This routes through the Registry's existing catch-all `handle_info(msg)` → `Source.handle_change_notification/2` path. No dedicated Registry `handle_info` clause is added. The source state machine contract is preserved.

`RotatingSecrets.Source.Memory.update(name, new_value)` is a public function; `name` is the atom registered with `RotatingSecrets.register/2`.

- `terminate/1`: `:ok`

### Phase 10 — Clustering Support

Scope is precisely bounded to PRD §9 requirements. Does NOT implement cluster-wide state replication or reconciliation (PRD §4 explicit non-goal).

**`lib/rotating_secrets/supervisor.ex`** (extend from Phase 5):
- Accept `registry_via: {Horde.Registry, MyApp.HordeRegistry}` option and use it as the via-tuple when starting Registry children. The library does NOT depend on Horde.

**`lib/rotating_secrets/registry.ex`** (extend from Phase 3):

1. **Horde migration correctness** (PRD §9.2): on process migration the new Registry process performs a fresh `init/1` + `handle_continue(:initial_load)`. child_spec must survive `:erlang.term_to_binary/1` round-trip (no closures, no PIDs, no refs).

2. **Per-node subscriber cleanup** (PRD §9.3):
   - `handle_info({:DOWN, _, :process, _, :noconnection}, state)` → remove subscriber, emit `[:rotating_secrets, :subscriber_removed]` telemetry with `reason: :noconnection`
   - `handle_info({:nodedown, node}, state)` → bulk-remove all subscribers on `node`, O(n) per node

3. **Opt-in `:pg` cluster broadcast, default-off** (PRD §9.4 — SHOULD-level):
   - Enabled via `config :rotating_secrets, cluster_broadcast: true, cluster_broadcast_group: :rotating_secrets_rotations`
   - On rotation, if enabled: broadcast `{:rotating_secret_rotated_cluster, node(), name, version}` to the `:pg` group
   - Broadcast failures MUST NOT affect local rotation; wrap in try/rescue

**`lib/rotating_secrets.ex`** (extend from Phase 6):

4. **`cluster_status/1`** (PRD §9.5):
   - `:rpc.multicall(Node.list(), RotatingSecrets.Registry, :version_and_meta, [name], 5_000)`
   - Fold results: `{node, {:ok, v, m}}` and `{node, {:badrpc, _}}` → `{:error, :noconnection}`
   - Never returns secret values

### Phase 11 — Tests

Layout per AGENTS.md (`test/<context>/<module>_test.exs`, `_properties_test.exs`, `_resilience_test.exs`).

**Dependency note:** Unit tests, property tests, and resilience tests do NOT depend on Phase 10 (clustering) and can begin as soon as Phase 9 (Memory source) is complete. Only `test/cluster/` is gated on Phase 10 completing.

**Unit tests:**
- `test/rotating_secrets/secret_test.exs` — Inspect/String.Chars/Jason.Encoder/Phoenix.Param leak prevention
- `test/rotating_secrets/registry_test.exs` — state machine, refresh, subscriber lifecycle; ≥90% line coverage
- `test/rotating_secrets/supervisor_test.exs` — startup, register/deregister
- `test/rotating_secrets/source/file_test.exs` — permission warning, interval mode, missing-on-refresh serves stale
- `test/rotating_secrets/source/env_test.exs` — dev warning, missing var
- `test/rotating_secrets/source/memory_test.exs` — `update/2` triggers rotation via `{channel_ref, :updated}` subscription message, not a direct Registry bypass
- `test/rotating_secrets/telemetry_test.exs` — all `[:rotating_secrets, ...]` events fire at correct times; none carry secret value; `:dev_source_in_use` fires on Env source init
- `test/rotating_secrets/log_capture_test.exs` — `ExUnit.CaptureLog` confirms no code path logs secret value

**Property tests (StreamData):**
- `test/rotating_secrets/rotation_consistency_properties_test.exs`
- `test/rotating_secrets/fail_soft_properties_test.exs`
- `test/rotating_secrets/subscriber_fanout_properties_test.exs`
- `test/rotating_secrets/monotone_versions_properties_test.exs`
- Generators: `test/support/generators.ex`

**Resilience tests (Snabbkaffe, `@tag :resilience`, NOT `async: true`):**
- `test/rotating_secrets/registry_resilience_test.exs` — crash during refresh: restarts, re-subscribes, re-notifies
- `test/rotating_secrets/source_resilience_test.exs` — `load/1` raises unexpected exception: caught, registry stays alive
- `test/rotating_secrets/subscriber_resilience_test.exs` — subscriber crashes mid-fanout: remaining subscribers still notified
- `test/rotating_secrets/file_source_resilience_test.exs` — FileSystem watcher crash: re-establishes, subsequent change triggers reload

**Integration tests:**
- `test/integration/file_source_integration_test.exs` — atomic rename triggers reload; concurrent reads during rotation see old-or-new, never nil

**Multi-node tests (`@tag :cluster`, gated on Phase 10):**
- `test/cluster/independent_registry_test.exs` — two-node cluster; rotate on node A; assert node B converges on same version
- `test/cluster/horde_migration_test.exs` — Horde-registered Registry migrates; subscribers continue to receive `{:rotating_secret_rotated, ref, name, version}` after migration
- `test/cluster/nodedown_test.exs` — subscriber on node B; kill node B; assert subscription removed and `[:rotating_secrets, :subscriber_removed]` fires; reconnecting nodes must re-subscribe explicitly
- `test/cluster/cluster_broadcast_test.exs` — enable `:pg` broadcast; rotate; assert `{:rotating_secret_rotated_cluster, _, name, version}` received on all nodes
- `test/cluster/netsplit_test.exs` — partition nodes; assert both sides serve last-known-good; heal; assert no errors
- `test/cluster/cluster_status_test.exs` — unreachable node returns `{:error, :noconnection}`; value never returned

### Phase 12 — Documentation

- Module docs + doctests on all public modules
- Conceptual overview (borrow / watch / metadata model) in top-level `RotatingSecrets` module doc
- `guides/getting_started.md` — Vault Agent + file source walkthrough
- `guides/rotation.md` — push vs pull, subscriber patterns
- `guides/security.md` — no-zeroize decision, `:sensitive` flag, leak discipline
- `guides/writing_a_source.md` — implementing the `Source` behaviour
- `guides/clustering.md` — independent-per-node default, Horde via `registry_via`, `:pg` cluster broadcast, `cluster_status/1`, nodedown subscriber cleanup
- `guides/testing.md` — using `Source.Memory.update/2` for in-process rotation, LocalCluster patterns, `rotating_secrets_testing` companion
- `specs/README.md` — TLC model-checking results
- ExDoc config in `mix.exs` with `extras:` pointing to all guides

### Phase 13 — Quality Gates

| Gate | Command | Target |
|---|---|---|
| Dialyzer | `mix dialyzer` | No warnings |
| Credo | `mix credo --strict` | No issues |
| Coverage | `mix test --cover` | ≥90% on Registry, Secret, Supervisor |
| Resilience | `mix test --only resilience` | All pass |
| Cluster | `mix test --only cluster` | All pass (requires LocalCluster) |
| HexDocs | `mix docs` | No warnings |
| Benchmark | `mix run benchmarks/current.exs` | ≥50k ops/s — manual gate; record result in `benchmarks/results/reference.md` |

---

## Acceptance Criteria

- [ ] Public API as specified in §6 is implemented and doctested.
- [ ] `Source.File`, `Source.Env`, `Source.Memory` implemented and pass tests in §10.
- [ ] All telemetry events in §7.5 fire at correct times; no event carries a secret value.
- [ ] Property tests for rotation consistency, fail-soft, version monotonicity, and subscriber fanout pass under 10,000+ generated cases.
- [ ] `current/1` benchmark achieves ≥50,000 ops/sec; result recorded in `benchmarks/results/reference.md` with CPU model, core count, Elixir version, OTP version, and exact command.
- [ ] Log capture tests confirm no code path leaks secret values.
- [ ] `Inspect`, `String.Chars`, `Jason.Encoder` (and `Phoenix.Param` when Phoenix is loaded) leak tests pass.
- [ ] Multi-node tests pass: independent convergence, Horde migration, subscriber cleanup on nodedown, `:pg` broadcast, netsplit tolerance, `cluster_status/1` with unreachable node.
- [ ] `cluster_status/1` implemented, tested, returns `{:error, :noconnection}` for unreachable nodes, never leaks values.
- [ ] HexDocs builds cleanly with no warnings.
- [ ] `dialyzer` passes with no warnings on library code.
- [ ] `credo --strict` passes.
- [ ] Companion packages `rotating_secrets_vault` and `rotating_secrets_testing` have their own PRDs and initial implementations.
- [ ] `Source.Memory.update/2` sends `{channel_ref, :updated}` via the subscription ref; Registry routes through `handle_change_notification/2`; tests confirm no Registry bypass.
- [ ] `registry_via` option accepted by Supervisor; Horde child_spec fully serializable; fresh `init/1` on migration verified in cluster tests.

---

## Notes for executor

- `Process.flag(:sensitive, true)` must be the first call in `init/1`, before `handle_continue` is scheduled
- PRD §8.1 specifies file permission check details and trailing whitespace stripping — reference PRD during Phase 7
- `subscribe/1` delivers notifications on changes only; subscribers call `current/1` explicitly after subscribing
- Rotation notification message: `{:rotating_secret_rotated, sub_ref, name, version}` — four elements; `version` lets subscribers detect skipped rotations without calling `current/1`
- Cluster broadcast message: `{:rotating_secret_rotated_cluster, node(), name, version}` — never the value
- `Jason.Encoder` defimpl must RAISE — not `@derive {Jason.Encoder, only: []}` which silently produces `{}`
- `FileSystem` must watch PARENT directory (not the file path) to capture `moved_to` from atomic rename
- Config key: `config :rotating_secrets, cluster_broadcast: true, cluster_broadcast_group: :rotating_secrets_rotations`
- `:pg` broadcast is SHOULD-level (PRD §9.4), default-off; broadcast failures must be silenced and never propagate to local rotation
- After adding deps: `mix deps.get && mix2nix > mix.nix && git add mix.nix`
- Commits: conventional (`feat:`, `fix:`, etc.), ≤72 chars first line, no tool attribution
- Resilience tests must NOT use `async: true` — Snabbkaffe trace state is process-global
- Unit/property/resilience tests are independent of Phase 10 (clustering); only `test/cluster/` is gated on Phase 10
- Benchmark results go to `benchmarks/results/reference.md`; file must record CPU model, core count, Elixir version, OTP version, exact command, and measured ops/sec figure
- **Plan file rename — ATOMIC commit required:** `git mv docs/plans/ex_secrets.md docs/plans/rotating_secrets.md`, update all memory file references, commit all three changes together in one commit
