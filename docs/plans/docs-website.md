# docs: generated website, API documentation, and user manual

Epic: secretmanager-ex-685

## Goal

Produce a single `nix build .#doc` output containing:
- ExDoc API reference for all three packages (`rotating_secrets`, `rotating_secrets_vault`, `rotating_secrets_testing`)
- mdBook user manual with narrative guides, cookbook patterns, and troubleshooting
- A root `index.html` linking both

## Current state

| Asset | State |
|---|---|
| `rotating_secrets/guides/` | 6 guides, 1037 lines — comprehensive |
| `rotating_secrets` `@moduledoc`/`@doc` | Present on most public modules; examples missing on several |
| `RotatingSecrets.Supervisor` | `register/2`, `deregister/2` — no `@doc` or `@spec` |
| `RotatingSecrets.Registry` | No `@doc` or `@spec` on any public function |
| `rotating_secrets_vault` | `KvV2` has `@moduledoc`; no `@doc` on individual functions |
| `rotating_secrets_testing` | Stub `@moduledoc` on all 3 modules; no `@doc` on individual callbacks |
| mdBook | Does not exist |
| `nix build .#doc` | Builds ExDoc for a single project only; no mdBook |

---

## Phase 1 — ExDoc audit and completion: `rotating_secrets`

**Task:** secretmanager-ex-685.1 · P1

Add `@doc` + `@spec` + `## Examples` to every public function currently lacking them.

### Gaps

| Module | Gap |
|---|---|
| `RotatingSecrets.Supervisor` | `register/2`, `deregister/2` — no `@doc` / `@spec` |
| `RotatingSecrets.Registry` | `child_spec/1`, `start_link/1`, `version_and_meta/1` — no `@doc` / `@spec` |
| `RotatingSecrets.Telemetry` | Individual `emit_*` functions — no `@doc` |
| `RotatingSecrets.Source.File` | Source behaviour callbacks — no `@doc` on `init/1`, `load/1`, `subscribe_changes/1`, `handle_change_notification/2`, `terminate/1` |
| `RotatingSecrets.Source.Env` | Same |
| `RotatingSecrets.Source.Memory` | Same |
| `RotatingSecrets` (main) | `with_secret/2`, `subscribe/1`, `unsubscribe/2`, `cluster_status/1` — missing `## Examples` blocks |

### Acceptance criteria

- `mix docs` in `rotating_secrets/` produces no warnings
- Every public function has at minimum one `## Examples` block with runnable Elixir

---

## Phase 2 — ExDoc audit and completion: `rotating_secrets_vault` and `rotating_secrets_testing`

**Task:** secretmanager-ex-685.2 · P2 · parallel with Phase 1

### `rotating_secrets_vault` gaps

| Module | Gap |
|---|---|
| `KvV2` | `init/1`, `load/1`, `subscribe_changes/1` — no `@doc` |
| `HTTP` | Internal module — confirm `@moduledoc false` and no public exports leak |

### `rotating_secrets_testing` gaps

| Module | Gap |
|---|---|
| `Source.Controllable` | All Source callbacks and `rotate/2` — no `@doc` / `@spec` |
| `Testing` | `assert_telemetry_event/2` needs full `@doc`; macro docs need complete examples |
| `Testing.Supervisor` | Already has `@moduledoc`; verify no gaps |

### Note on `rotating_secrets_testing` stability

The `Testing` module is a planning stub. `@doc` annotations must explicitly note that the full helper API is provisional pending a dedicated PRD. Do not document provisional behaviour as stable.

### Acceptance criteria

- `mix docs` in both packages produces no warnings
- `rotate/2` example shows the full test setup (start supervisors → register → subscribe → rotate → assert)

---

## Phase 3 — mdBook scaffold and user manual content

**Task:** secretmanager-ex-685.3 · P1 · parallel with Phases 1–2

### Directory structure

```
docs/book/
├── book.toml
├── src/
│   ├── SUMMARY.md
│   ├── introduction.md           # what rotating_secrets is; when to use it
│   ├── concepts/
│   │   ├── secret_lifecycle.md   # state machine, TTL, versioning
│   │   ├── sources.md            # source abstraction; built-ins catalogue
│   │   └── security_model.md     # opaque Secret, leak prevention
│   ├── quickstart.md             # supervisor → register → read in 5 minutes
│   ├── cookbook/
│   │   ├── file_source.md        # prod pattern: systemd credentials
│   │   ├── vault_source.md       # KV v2 with OpenBao/Vault
│   │   ├── subscriptions.md      # reacting to rotations
│   │   └── custom_source.md      # step-by-step source implementation
│   ├── telemetry.md              # all events; handler setup
│   ├── clustering.md             # Horde, pg2 patterns
│   ├── testing.md                # Controllable, Testing macros, property tests
│   └── troubleshooting.md        # 15+ error entries with root cause + fix
└── theme/                        # optional branding
```

### `book.toml` key settings

```toml
[book]
title = "RotatingSecrets User Manual"
authors = ["urist"]
src = "src"

[output.html]
site-url = "/manual/"
```

### Cross-linking policy

Each page that references an API must link to `../../api/rotating_secrets/` (relative to
the manual output root). Do not inline API signatures — link to ExDoc instead.

### Acceptance criteria

- `mdbook build` succeeds with no warnings
- SUMMARY.md lists all pages; all pages exist
- `troubleshooting.md` contains at least 15 distinct error entries, each with: exact error
  message, symptom, root cause, fix, prevention
- Every cookbook page contains a complete runnable example

---

## Phase 4 — `nix build .#doc` flake integration

**Task:** secretmanager-ex-685.4 · P1 · depends on Phases 1, 2, 3

### Output layout

```
$out/
├── index.html                    # links to manual/ and api/
├── manual/                       # mdBook HTML
└── api/
    ├── rotating_secrets/          # ExDoc HTML
    ├── vault/                     # ExDoc HTML
    └── testing/                   # ExDoc HTML
```

### Build steps inside the derivation

```bash
# 1. ExDoc — each package in order (vault depends on rotating_secrets)
cd rotating_secrets && mix deps.get && mix docs
mkdir -p $out/api/rotating_secrets && cp -r doc/* $out/api/rotating_secrets/

cd ../rotating_secrets_vault && mix deps.get && mix docs
mkdir -p $out/api/vault && cp -r doc/* $out/api/vault/

cd ../rotating_secrets_testing && mix deps.get && mix docs
mkdir -p $out/api/testing && cp -r doc/* $out/api/testing/

# 2. mdBook
mdbook build docs/book --dest-dir $out/manual

# 3. Root index
cp docs/book/index-redirect.html $out/index.html
```

### `nativeBuildInputs` additions

- `pkgs.mdbook`
- `elixir` (already present)
- `pkgs.git` (already present)

### Acceptance criteria

- `nix build .#doc` exits 0
- `result/index.html` exists and links to both `manual/` and `api/rotating_secrets/`
- All three ExDoc outputs present under `result/api/`

---

## Phase 5 — Validation

**Task:** secretmanager-ex-685.5 · P1 · depends on Phase 4

### Checks

1. `nix build .#doc` — clean build, no errors or warnings
2. ExDoc search — query `"RotatingSecrets"`, `"rotate"`, `"subscribe"` — results returned
3. mdBook internal links — `mdbook test` and manual spot-check of cross-links
4. API links from manual pages — at least 5 spot-checked against actual ExDoc output
5. All `## Examples` in ExDoc are valid Elixir syntax (`mix compile` does not reject them)

---

## Dependency graph

```
685.1 (ExDoc rotating_secrets)   685.2 (ExDoc vault+testing)   685.3 (mdBook)
         │                                │                          │
         └──────────────────┬────────────┘                          │
                            ▼                                        │
                     685.4 (Nix build) ◄────────────────────────────┘
                            │
                            ▼
                     685.5 (Validation)
```

## Risks

- **mdBook ↔ ExDoc link fragility** if output paths shift. Anchor to relative paths and
  verify in Phase 5.
- **`rotating_secrets_testing` stability caveat**: document as provisional until the
  testing PRD is approved.
- **Nix sandbox + network**: `mix deps.get` inside a derivation requires either
  `--no-sandbox` or pre-fetched deps. Extend the existing `docs` derivation pattern —
  do not rewrite from scratch.
