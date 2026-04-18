# Plan: `rotating_secrets_vault` — Vault HTTP Source Companion Package

**Status:** Approved
**Beads epic:** secretmanager-ex-lse.15
**Date:** 2026-04-18
**Depends on:** `rotating_secrets` core (secretmanager-ex-lse — blocked until core publishes to Hex)

---

## ADR

**Decision:** Implement `rotating_secrets_vault` as three thin public `@behaviour RotatingSecrets.Source` modules (`KvV2`, `KvV1`, `Dynamic`) backed by a private shared HTTP core (`Vault.HTTP`). No `type:` dispatch.

**Drivers:**
1. Core package has zero HTTP dependencies by design (PRD §4, §11); all HTTP lives in this companion.
2. KV v2, KV v1, and dynamic secrets have materially different response shapes and version semantics; a single `type:`-dispatching module re-invents what the `@behaviour` contract provides.
3. `req ~> 0.5` is the HTTP client per PRD §11; `Req.Test` plug injection enables testing without a live Vault.

**Alternatives considered:**
- Single `Source.Vault` module with `type:` opt — rejected: hides three incompatible state shapes behind one map; Dialyzer cannot help; extension is non-idiomatic.
- Req plugin / middleware — rejected: inverts the `init/1`/`load/1`/`terminate/1` behaviour contract.

**Consequences:**
- Three small independent modules are easy to extend (Transit, PKI, AWS → new module implementing `@behaviour RotatingSecrets.Source`).
- `Vault.HTTP` is the single attack surface for HTTP-level security review.
- Vault push notifications are not supported (no Vault HTTP push primitive); Registry falls back to TTL-driven polling.

---

## RALPLAN-DR

**Principles**
1. Security-first: Vault token, lease ID, and secret material never in logs, telemetry, crash reports, or error tuples.
2. Source behaviour purity: each module implements exactly `@behaviour RotatingSecrets.Source`; no new GenServer, no supervision tree.
3. Minimal runtime deps: `rotating_secrets` + `req` only.
4. Fail-soft defers to the Registry: `load/1` returns `{:error, reason, state}` (transient); never crashes.
5. No Vault administrative operations (no lease renewal, no token renewal — PRD §4).
6. `init/1` error safety: validation errors never echo back the opts keyword list (token leak prevention).

**Decision Drivers**
1. PRD §4/§11 mandate no HTTP in core; companion packages carry HTTP.
2. Vault Agent is the primary production target; direct API is supported via `deployment_model:` opt.
3. HTTP 403 is mapped to a **transient** error in both deployment modes because Vault error strings (distinguishing token expiry from ACL denial) are not API-stable across Vault versions.
4. KV v1 has no version metadata; `version: nil` with `content_hash:` meta preserves the `MonotoneVersions` TLA+ invariant in the core spec.
5. Dynamic secrets create orphaned Vault leases on each `load/1`; this is acknowledged as a known limitation and documented.

---

## Design Decisions

### DD-1: Module Architecture

```
rotating_secrets_vault/
  lib/
    rotating_secrets/
      source/
        vault.ex           # thin alias — @moduledoc pointing to KvV2/KvV1/Dynamic
        vault/
          http.ex          # private (@moduledoc false) — shared HTTP core
          kv_v2.ex         # public, @behaviour RotatingSecrets.Source
          kv_v1.ex         # public, @behaviour RotatingSecrets.Source
          dynamic.ex       # public, @behaviour RotatingSecrets.Source
```

Callers use modules directly, analogous to `Source.File`:
```elixir
RotatingSecrets.register(:db_creds,
  source: {RotatingSecrets.Source.Vault.KvV2,
           address: "http://127.0.0.1:8200",
           mount: "secret",
           path: "myapp/db",
           token: System.fetch_env!("VAULT_TOKEN")})
```

### DD-2: State Structs

**`KvV2` state:**
```elixir
%{address: binary(), mount: binary(), path: binary(), token: binary(),
  namespace: binary() | nil, deployment_model: :vault_agent | :direct,
  base_req: Req.Request.t()}
```

**`KvV1` state:**
```elixir
%{address: binary(), mount: binary(), path: binary(), key: binary(),
  token: binary(), namespace: binary() | nil,
  deployment_model: :vault_agent | :direct, base_req: Req.Request.t()}
```

**`Dynamic` state:**
```elixir
%{address: binary(), mount: binary(), path: binary(), key: binary() | nil,
  token: binary(), namespace: binary() | nil,
  deployment_model: :vault_agent | :direct, base_req: Req.Request.t(),
  lease_id: binary() | nil, lease_duration_ms: non_neg_integer() | nil}
```

### DD-3: Version Semantics

| Source  | `meta.version`               | `meta.content_hash`                      |
|---------|------------------------------|------------------------------------------|
| KvV2    | `integer` (from Vault metadata, monotone) | `base16_sha256(material)` |
| KvV1    | `nil` (Vault KV v1 has no version concept) | `base16_sha256(material)` |
| Dynamic | `nil` (leases are not versioned)           | `base16_sha256(material)` |

`version: nil` signals to the Registry that no ordered version is available. The core `MonotoneVersions` TLA+ invariant (`specs/registry.tla`) must be updated to apply only to non-nil versions:
```tla
MonotoneVersions == \A s \in secrets :
  s.version # nil => \* ... monotone check only for non-nil versions
```

### DD-4: Complete HTTP Error Mapping (All Transient)

All `load/1` errors return `{:error, error_atom, state}`. No error is permanent; all trigger the Registry's exponential-backoff retry path and serve last-known-good after initial success.

| HTTP status / condition | Error atom | Notes |
|---|---|---|
| 403 | `:vault_auth_error` | **Transient** in both deployment modes. Vault error strings are not API-stable; body parsing is not used. Operators inspect Vault audit logs to distinguish token expiry from ACL denial. |
| 404 | `:vault_secret_not_found` | Transient: bootstrap race or transient misconfiguration. |
| 429 | `:vault_rate_limited` | Transient. |
| 500, 502, 503, 504 | `:vault_server_error` | Transient: Vault unavailable or degraded. |
| Other 4xx | `:vault_client_error` | Transient. |
| TCP connection refused | `:vault_connection_refused` | Transient: sidecar not yet ready. |
| Timeout | `:vault_timeout` | Transient. |
| TLS handshake failure | `:vault_tls_error` | Transient: certificate rotation or misconfigured CA. |
| Unexpected exception | `:vault_unexpected_error` | Transient. Details logged at `:error` without secret material. |

Rationale for 403-transient: distinguishing "expired token" from "ACL gap" requires parsing `body["errors"]`, which contains human-readable strings that have changed between Vault minor versions and are not a stable API contract.

### DD-5: `init/1` Error Safety

Validation errors must not include the opts keyword list (which contains the `token:` value) in the error reason:

```elixir
# CORRECT
{:error, {:invalid_option, :address}}
{:error, {:invalid_option, {:namespace, :expected_non_empty_binary}}}

# FORBIDDEN — leaks token into supervisor logs
{:error, {:invalid_option, opts}}
{:error, {:bad_opts, keyword_list}}
```

### DD-6: Deployment Model

`deployment_model: :vault_agent | :direct` (default `:vault_agent`) is stored in state and passed to `Vault.HTTP`. Both modes use identical HTTP error mapping (DD-4). The option is provided for documentation/observability purposes; it does not change error semantics in v1.

### DD-7: Namespace Support

`namespace:` is a first-class `init/1` option. When present:
- Validated as non-empty binary; error: `{:error, {:invalid_option, {:namespace, :expected_non_empty_binary}}}`
- Injected as `X-Vault-Namespace` header by `Vault.HTTP.base_request/1` on every request

When absent or `nil`, the header is not sent.

### DD-8: Token Management — Explicitly Out of Scope

Token renewal is not implemented. `guides/vault.md` must state: "Token management — renewal, re-authentication, and TTL extension — is the operator's responsibility. Use Vault Agent (`deployment_model: :vault_agent`, the default) for production."

### DD-9: `req_options:` Testing Seam

`init/1` accepts `req_options: keyword()` which is merged into `Req.new/1`. This is the documented injection path for `Req.Test` in tests:

```elixir
# In test setup:
Req.Test.stub(:vault_test, fn conn -> ... end)
{:ok, state} = KvV2.init([..., req_options: [plug: {Req.Test, :vault_test}]])
```

This option is an escape hatch; it has no validation and is not recommended for production use. `guides/vault.md` documents that `req_options` is for testing only.

### DD-10: Dynamic Secret Orphaned Leases (Known Limitation)

Each `load/1` on `Source.Vault.Dynamic` issues a new Vault lease. The prior lease is never revoked (PRD §4: no administrative operations). In a production system with 60s TTL and 40s refresh cycles, this creates unbounded orphaned lease accumulation.

Operator guidance (documented in `guides/vault.md` "Known Limitations" section):
1. Configure Vault's `lease_count_quota` to bound accumulation.
2. Leases created by a token are revoked when that token expires — size the token TTL accordingly.
3. Prefer short lease TTLs so Vault's own TTL expiry reclaims orphaned leases.
4. If lease accumulation is unacceptable for the workload, use `Source.Vault.KvV2` with a static credential instead of dynamic secrets.

### DD-11: Dependency Bootstrapping

`rotating_secrets_vault` depends on the core `rotating_secrets` library. During development (before the core is published to Hex), use a path dep:

```elixir
# mix.exs — development only
{:rotating_secrets, path: "../rotating_secrets"}
```

Switch to the Hex dep before the first publish:

```elixir
# mix.exs — publish
{:rotating_secrets, "~> 0.1"}
```

The CI publish job (`.github/workflows/publish.yml`) must verify no path dep is present:
```bash
grep -E 'path:' mix.exs && echo "ERROR: path dep found" && exit 1 || true
```

---

## Phases

### Phase V0 — Scaffold

- `mix new rotating_secrets_vault --module RotatingSecretsVault` in `rotating_secrets_vault/`
- `mix.exs`: runtime deps `{:rotating_secrets, path: "../rotating_secrets"}` (dev) + `{:req, "~> 0.5"}`; dev/test deps `{:mox, "~> 1.0", only: :test}`, `{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}`, `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}`, `{:ex_doc, "~> 0.34", only: :dev, runtime: false}`
- Stub modules: `lib/rotating_secrets/source/vault.ex` (moduledoc only), `lib/rotating_secrets/source/vault/http.ex` (`@moduledoc false`), `lib/rotating_secrets/source/vault/kv_v2.ex`, `lib/rotating_secrets/source/vault/kv_v1.ex`, `lib/rotating_secrets/source/vault/dynamic.ex` (all behaviours stubbed to raise `"not implemented"`)
- `.credo.exs` (strict baseline), `.formatter.exs`, `.gitignore`
- `mix deps.get && mix2nix > mix.nix`
- CI: GitHub Actions with dialyzer PLT caching at `.github/workflows/ci.yml`

**Acceptance criteria:**
- `mix compile` passes with no warnings
- `mix credo --strict` passes on stub files
- `mix dialyzer` passes

### Phase V1 — `Vault.HTTP` private core + `KvV2`

**`Vault.HTTP` (private) responsibilities:**
- `base_request/1`: builds `Req.new(base_url: address, headers: [{"x-vault-token", token}] ++ namespace_header(namespace), receive_timeout: timeout_ms)` merged with `req_options:`
- `namespace_header(nil)` → `[]`; `namespace_header(ns)` → `[{"x-vault-namespace", ns}]`
- `get/2`: `Req.get(base_req, url: path)` → normalise result via `normalise_response/1`
- `normalise_response/1`: maps HTTP status codes to error atoms per DD-4

**`KvV2.init/1`:**
- Required opts: `:address`, `:mount`, `:path`, `:token`
- Optional: `:namespace` (validated non-empty binary), `:deployment_model` (default `:vault_agent`), `:req_options` (list, merged into `Req.new/1` — testing seam)
- Validation errors: `{:error, {:invalid_option, key}}` or `{:error, {:invalid_option, {key, :expected_non_empty_binary}}}` — never full opts list
- Builds `base_req` via `Vault.HTTP.base_request/1`; returns `{:ok, state}`

**`KvV2.load/1`:**
- URL: `"/v1/#{mount}/data/#{path}"`
- On 200: extract `body["data"]["data"]` (material); `body["data"]["metadata"]["version"]` (integer); `body["data"]["metadata"]["created_time"]` (string); `content_hash: base16_sha256(material)`
- TTL: `body["lease_duration"]` if non-zero (seconds → ms), else `nil`
- Returns `{:ok, material, meta, state}` or `{:error, error_atom, state}`

**`KvV2.subscribe_changes/1`:** `:not_supported`
**`KvV2.handle_change_notification/2`:** `:ignored`
**`KvV2.terminate/1`:** `:ok`

**Tests (`test/rotating_secrets/source/vault/kv_v2_test.exs`):**
- All using `Req.Test` plug injection via `req_options: [plug: {Req.Test, :vault}]`
- Happy path: material extracted, `meta.version` integer, `meta.content_hash` present
- 403 → `:vault_auth_error` (in both deployment modes)
- 404 → `:vault_secret_not_found`
- 429 → `:vault_rate_limited`
- 503 → `:vault_server_error`
- Timeout → `:vault_timeout`
- `namespace:` injects `X-Vault-Namespace` header; absent when `nil`
- `init/1` with invalid namespace: `{:error, {:invalid_option, {:namespace, :expected_non_empty_binary}}}`
- `init/1` error tuple does not contain the token value string in its inspected form

**Acceptance criteria:** All V1 tests pass; `mix dialyzer` passes; `mix credo --strict` passes.

### Phase V2 — `KvV1` and `Dynamic`

**`KvV1.load/1`:**
- URL: `"/v1/#{mount}/#{path}"`
- Required opt: `:key` (binary, key within the data map)
- Material: `body["data"][key]`
- Meta: `%{version: nil, content_hash: base16_sha256(material)}`
- TTL: `nil` (KV v1 has no lease)

**`Dynamic.load/1`:**
- URL: `"/v1/#{mount}/creds/#{path}"` (or override with full path)
- Material: if `key:` given, `body["data"][key]`; otherwise `Jason.encode!(body["data"])`
- Meta: `%{version: nil, content_hash: base16_sha256(material), lease_id: body["lease_id"], lease_duration_ms: body["lease_duration"] * 1000}` (when `lease_duration > 0`)
- TTL: `lease_duration_ms` (drives Registry 2/3-lifetime refresh)

**Tests:** mirror V1 test structure; additional:
- KvV1: `meta.version` is `nil`; same-value re-issue → same `content_hash`; different values → different `content_hash`; missing `:key` opt → `{:error, {:invalid_option, :key}}`
- Dynamic: `lease_id` and `lease_duration_ms` in meta; `version: nil`; short lease (300ms) in Req.Test → Registry schedules refresh within 200ms window (not 60s → 40s: use ms-scale to avoid CI flap)

**Acceptance criteria:** All V1 + V2 tests pass; `mix dialyzer` passes; `mix credo --strict` passes.

### Phase V3 — Integration Test with `RotatingSecrets.Registry`

Using `Req.Test` plug. A real `RotatingSecrets.Registry` is started with `source: {KvV2, ..., req_options: [...]}`.

Test scenarios:
1. Initial load → `RotatingSecrets.current/1` returns `{:ok, secret}`
2. Rotation: change Req.Test response; trigger refresh via `send(pid, :do_refresh)`; assert subscriber notification; assert new `current/1` material
3. 503 on refresh → `current/1` returns last-known-good (fail-soft)
4. 403 on refresh → `current/1` returns last-known-good (fail-soft, transient treatment verified)
5. Dynamic TTL: `lease_duration: 300ms` in Req.Test → assert refresh triggered within 400ms (generous window)
6. Telemetry: no `[:rotating_secrets, ...]` event contains material or token

**Acceptance criteria:** All integration tests pass without a live Vault.

### Phase V4 — Quality Gates and Documentation

**`guides/vault.md` structure:**
```
## Known Limitations       ← FIRST SUBSECTION (required by AC)
  - Orphaned dynamic leases (per DD-10)
  - No push notifications (`:not_supported`)
  - No token renewal (operator responsibility)
  - No version pinning for KV v2 (deferred)

## Getting Started (Vault Agent mode)
## Direct Vault API (no Vault Agent)
## KV Secrets Engine v2
## KV Secrets Engine v1
## Dynamic Secrets
## Namespace Support (Vault Enterprise)
## Testing with Req.Test
## Deferred Features
```

**Quality gates:**

| Gate | Command | Target |
|---|---|---|
| Dialyzer | `mix dialyzer` | No warnings |
| Credo | `mix credo --strict` | No issues |
| Coverage | `mix test --cover` | ≥90% on KvV2, KvV1, Dynamic, HTTP |
| HexDocs | `mix docs` | No warnings |

**Acceptance criteria:** All four gates pass; `mix hex.build` succeeds.

---

## Acceptance Criteria

- [ ] `RotatingSecrets.Source.Vault.KvV2`, `KvV1`, and `Dynamic` each implement `@behaviour RotatingSecrets.Source` directly. No `type:` dispatch. Dialyzer passes with no warnings on all three modules.
- [ ] `RotatingSecrets.Source.Vault.HTTP` is private (`@moduledoc false`); no external caller references it directly.
- [ ] Complete HTTP error table (DD-4) is implemented: all errors return transient `{:error, error_atom, state}`; no HTTP or network error is treated as permanent by the Registry.
- [ ] 403 → `:vault_auth_error` (transient) in both deployment modes; tested via Req.Test.
- [ ] Fail-soft: 503 on refresh → last-known-good returned, Registry does not crash. Tested in integration test (Phase V3).
- [ ] Fail-soft: 403 on refresh → last-known-good returned, Registry does not crash. Tested in integration test (Phase V3).
- [ ] KV v2: `meta.version` is integer (from Vault metadata); `meta.content_hash` present.
- [ ] KV v1: `meta.version` is `nil`; `meta.content_hash` present; same-value re-issue produces same hash; different values produce different hash.
- [ ] Dynamic: `meta.version` is `nil`; `meta.lease_id` and `meta.lease_duration_ms` present when non-zero.
- [ ] Dynamic TTL drives Registry refresh scheduling (integration test: short mock lease → refresh within generous window).
- [ ] `namespace:` validated as non-empty binary in `init/1`; injected as `X-Vault-Namespace` header by `Vault.HTTP`; absent when `nil`; tested.
- [ ] `init/1` error returns must not include raw opts or token value. Errors use `{:error, {:invalid_option, key}}` or `{:error, {:invalid_option, {key, :expected_non_empty_binary}}}`. Test asserts error tuple does not contain the token value string in its inspected form.
- [ ] Dynamic orphaned lease accumulation documented in `guides/vault.md` "Known Limitations" (first subsection) with operator guidance: `lease_count_quota`, token-TTL reclamation, short lease TTLs, KV v2 as alternative.
- [ ] `guides/vault.md` "Known Limitations" is the first subsection.
- [ ] Token management explicitly documented as operator's responsibility in `guides/vault.md`.
- [ ] `req_options:` testing seam documented as test-only in `guides/vault.md`.
- [ ] No Vault push notifications: `subscribe_changes/1` returns `:not_supported` for all three modules; Registry falls back to TTL/interval polling; tested.
- [ ] `mix.exs` uses `{:rotating_secrets, path: "../rotating_secrets"}` during development. Path dep replaced with `{:rotating_secrets, "~> 0.1"}` before publish. CI publish step verifies no `path:` dep in `mix.exs`.
- [ ] All Vault source tests use `Req.Test` plug injection. No live Vault required.
- [ ] `mix dialyzer` passes with no warnings.
- [ ] `mix credo --strict` passes.
- [ ] HexDocs builds cleanly with no warnings.
- [ ] No telemetry event or log line emitted by this library contains a Vault token or secret material.
- [ ] `core MonotoneVersions` TLA+ invariant in `specs/registry.tla` updated to exclude nil versions; TLC re-run; `specs/README.md` updated.
- [ ] Version pinning (`?version=N` for KV v2) documented as deferred in `guides/vault.md`.

---

## Notes for Executor

- `Vault.HTTP.base_request/1` is called in `init/1` and the result stored in state — never rebuilt per-call (avoids re-allocation on hot path)
- `content_hash` uses `Base.encode16(:crypto.hash(:sha256, material), case: :lower)` — lowercase hex, consistent across all three source types
- `Jason` is a transitive dep through `req`; use `Jason.encode!/1` for multi-field dynamic material without adding `jason` as a direct dep
- `subscribe_changes/1` returning `:not_supported` means `handle_change_notification/2` is unreachable; it must still be implemented (returns `:ignored`) to satisfy the behaviour
- Dynamic TTL integration test must use ms-scale durations (e.g., `lease_duration: 0.3` seconds = 300ms) to avoid CI timing flap — never use second-scale waits in CI
- `mix.exs` dep comment: `# req ~> 0.5: verify against your project's mix.lock before upgrading`
- Commit message: `feat: add rotating_secrets_vault companion package` (first commit after V0 scaffold)
- After any dep change: `mix deps.get && mix2nix > mix.nix && git add mix.nix`
