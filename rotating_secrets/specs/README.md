# Registry TLA+ Specification

Formal specification of the `RotatingSecrets.Registry` secret-lifecycle state machine,
verified with TLC (TLA+ model checker).

## State Machine

A single secret entry managed by the registry passes through five states.

```
          ┌──────────────────────────────────────────────┐
          │                                              │
          ▼                                              │
      [Loading] ──LoadSucceeded──► [Valid] ◄──ExpiringRefreshSucceeded──┐
          │                          │  │                               │
          │                     StartRefresh  StartExpiring             │
       LoadFailed                    │  │                               │
          │                          ▼  ▼                               │
          │                    [Refreshing]  [Expiring] ────────────────┘
          │                          │          │
          │                  RefreshSucceeded   Expire
          │                  RefreshFailed──►   │
          │                          └──► [Expiring]
          │                                     │
          │                                  Expire
          ▼                                     ▼
      [Expired] ◄──────────────────────────[Expired]
          │
          └──Restart──► [Loading]
```

### States

| State | Description |
|-------|-------------|
| `Loading` | Initial state; no value available yet. Source is being contacted. |
| `Valid` | A value has been successfully loaded and is within its TTL. |
| `Refreshing` | TTL approaching; background refresh in progress. Old value still served. |
| `Expiring` | Refresh failed or TTL nearly elapsed. Stale value may still be served. |
| `Expired` | TTL elapsed; secret is no longer served. Registry will restart the cycle. |

### Transitions

| From | To | Action |
|------|----|--------|
| `Loading` | `Valid` | `LoadSucceeded` — source returned a value |
| `Loading` | `Expired` | `LoadFailed` — source permanently unavailable |
| `Valid` | `Refreshing` | `StartRefresh` — background refresh triggered |
| `Valid` | `Expiring` | `StartExpiring` — TTL near expiry, no refresh scheduled |
| `Refreshing` | `Valid` | `RefreshSucceeded` — refresh returned new value |
| `Refreshing` | `Expiring` | `RefreshFailed` — refresh failed, value is stale |
| `Expiring` | `Valid` | `ExpiringRefreshSucceeded` — refresh succeeded before full expiry |
| `Expiring` | `Expired` | `Expire` — TTL elapsed |
| `Expired` | `Loading` | `Restart` — registry restarts the load cycle |

## Invariants

Three safety invariants must hold in every reachable state:

**`TypeInvariant`**
Every variable remains within its declared domain at all times:
- `state ∈ {Loading, Valid, Refreshing, Expiring, Expired}`
- `current_value ∈ {Nil, Set}`
- `version ∈ 0..MAX_VERSION`

**`NoNilAfterLoad`**
Once the first load succeeds the secret value is never nil again.
Formally: `state ∈ {Valid, Refreshing, Expiring} ⇒ current_value = Set`

This captures the fail-soft requirement: even while refreshing or expiring,
consumers always receive the last-known-good value.

**`MonotoneVersions`** (action property)
The version counter never decreases across any step:
`[][version' ≥ version]_version`

This ensures consumers observe non-decreasing version sequences, which is the
foundation for optimistic concurrency and cache-invalidation logic.

## Liveness Property

**`EventuallyValid`**: `◇(state = Valid)`

A registry with a reachable source eventually reaches the `Valid` state.
Proved under *strong fairness* on success transitions (SF): if `LoadSucceeded`,
`RefreshSucceeded`, or `ExpiringRefreshSucceeded` are enabled infinitely often,
they must eventually fire.

> Strong fairness is the right assumption here: a reachable source may fail
> transiently (LoadFailed can fire), but if the source is eventually reachable
> it will respond successfully at least once.  Weak fairness was insufficient
> because LoadFailed can interrupt LoadSucceeded each time the system returns to
> Loading, preventing continuous enablement.

## TLC Results (MAX_VERSION = 3)

```
TLC2 Version 2.19 of 08 August 2024
Model checking completed. No error has been found.

31 states generated, 17 distinct states found, 0 states left on queue.
State graph depth: 9
Average outdegree: 1 (min 0, max 2, 95th pct 2)
Checked: TypeInvariant, NoNilAfterLoad, MonotoneVersions, EventuallyValid
Fingerprint collision probability: ~1.3E-17
Finished in 01s
```

All invariants hold across all 17 reachable states. The liveness property
`EventuallyValid` is verified for the complete state space with strong fairness.

## Files

| File | Description |
|------|-------------|
| `registry.tla` | TLA+ specification (states, transitions, invariants, liveness) |
| `registry.cfg` | TLC configuration (SPECIFICATION, INVARIANT, PROPERTY, CONSTANT) |
| `README.md` | This document |

## Running TLC

```bash
cd rotating_secrets/specs
tlc registry.tla -config registry.cfg
```
