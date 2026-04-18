---- MODULE registry ----
\* TLA+ specification for the RotatingSecrets.Registry state machine.
\*
\* Models the lifecycle of a single secret entry managed by the registry.
\* A secret passes through five states from initial load through expiry and
\* optional restart.  Three safety invariants and one liveness property are
\* verified by TLC.
EXTENDS Naturals

CONSTANTS
  MAX_VERSION   \* upper bound on the version counter (keep small for TLC)

VARIABLES
  state,         \* current lifecycle state of the secret
  current_value, \* "Nil" until first successful load; "Set" thereafter
  version        \* monotonically non-decreasing load counter

vars == <<state, current_value, version>>

(***************************************************************************)
(* State space                                                              *)
(***************************************************************************)

States == {"Loading", "Valid", "Refreshing", "Expiring", "Expired"}

(***************************************************************************)
(* Invariants                                                               *)
(***************************************************************************)

\* Every variable stays within its declared type at all times.
TypeInvariant ==
  /\ state         \in States
  /\ current_value \in {"Nil", "Set"}
  /\ version       \in 0..MAX_VERSION

\* Once the first load succeeds the secret value is never nil again.
\* (Loading and Expired are the only states where current_value may be Nil.)
NoNilAfterLoad ==
  state \in {"Valid", "Refreshing", "Expiring"} => current_value = "Set"

\* The version counter never decreases — readers observe non-decreasing versions.
MonotoneVersions == [][version' >= version]_version

(***************************************************************************)
(* Initial state                                                            *)
(***************************************************************************)

Init ==
  /\ state         = "Loading"
  /\ current_value = "Nil"
  /\ version       = 0

(***************************************************************************)
(* Transitions                                                              *)
(***************************************************************************)

\* Helper: increment version up to MAX_VERSION.
NextVersion == IF version < MAX_VERSION THEN version + 1 ELSE version

\* Loading -> Valid: source returns a value on the first attempt.
LoadSucceeded ==
  /\ state = "Loading"
  /\ state'         = "Valid"
  /\ current_value' = "Set"
  /\ version'       = NextVersion

\* Loading -> Expired: source fails permanently; no value ever delivered.
LoadFailed ==
  /\ state  = "Loading"
  /\ state' = "Expired"
  /\ UNCHANGED <<current_value, version>>

\* Valid -> Refreshing: a background refresh is triggered (TTL approaching or
\* explicit refresh call).  The existing value remains available to readers.
StartRefresh ==
  /\ state  = "Valid"
  /\ state' = "Refreshing"
  /\ UNCHANGED <<current_value, version>>

\* Valid -> Expiring: TTL is near expiry and no refresh has been scheduled.
StartExpiring ==
  /\ state  = "Valid"
  /\ state' = "Expiring"
  /\ UNCHANGED <<current_value, version>>

\* Refreshing -> Valid: the refresh call returns a new value.
RefreshSucceeded ==
  /\ state          = "Refreshing"
  /\ state'         = "Valid"
  /\ current_value' = "Set"
  /\ version'       = NextVersion

\* Refreshing -> Expiring: the refresh call fails; the value is now stale.
RefreshFailed ==
  /\ state  = "Refreshing"
  /\ state' = "Expiring"
  /\ UNCHANGED <<current_value, version>>

\* Expiring -> Valid: a load or refresh succeeds before the TTL fully expires.
ExpiringRefreshSucceeded ==
  /\ state          = "Expiring"
  /\ state'         = "Valid"
  /\ current_value' = "Set"
  /\ version'       = NextVersion

\* Expiring -> Expired: TTL elapsed; secret is no longer served to callers.
Expire ==
  /\ state  = "Expiring"
  /\ state' = "Expired"
  /\ UNCHANGED <<current_value, version>>

\* Expired -> Loading: registry restarts the load cycle for the secret.
Restart ==
  /\ state  = "Expired"
  /\ state' = "Loading"
  /\ UNCHANGED <<current_value, version>>

Next ==
  \/ LoadSucceeded
  \/ LoadFailed
  \/ StartRefresh
  \/ StartExpiring
  \/ RefreshSucceeded
  \/ RefreshFailed
  \/ ExpiringRefreshSucceeded
  \/ Expire
  \/ Restart

(***************************************************************************)
(* Fairness                                                                 *)
(***************************************************************************)

\* Strong fairness on the "happy path" transitions: if a success action is
\* enabled infinitely often it must eventually fire.  This models the
\* assumption that a reachable source will eventually respond successfully.
\* WF is insufficient because LoadFailed can interrupt LoadSucceeded each
\* time the system returns to Loading, preventing continuous enablement.
Fairness ==
  /\ SF_vars(LoadSucceeded)
  /\ SF_vars(RefreshSucceeded)
  /\ SF_vars(ExpiringRefreshSucceeded)
  /\ WF_vars(Restart)

(***************************************************************************)
(* Full specification                                                       *)
(***************************************************************************)

Spec == Init /\ [][Next]_vars /\ Fairness

(***************************************************************************)
(* Liveness                                                                 *)
(***************************************************************************)

\* A registry with a reachable source eventually delivers a valid secret.
EventuallyValid == <>(state = "Valid")

====
