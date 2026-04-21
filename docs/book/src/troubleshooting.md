# Troubleshooting

## `{:error, :not_registered}` from `current/1`

**Error / symptom:**

```elixir
{:error, :not_registered} = RotatingSecrets.current(:db_password)
```

**Root cause:**

No secret has been registered under that name. Either `register/2` was never called, it returned an error that was silently ignored, or the secret was deregistered before this call.

**Fix:**

1. Confirm `register/2` is called before `current/1` in your startup sequence.
2. Check the return value of `register/2` — if it returned `{:error, reason}`, the registration failed and no process was started.
3. If you called `deregister/1`, ensure it is only called when intentional.
4. In tests, ensure `RotatingSecrets.Supervisor` is started via `start_supervised!` before registering.

**Prevention:**

Pattern-match the return value of `register/2` and raise on error rather than ignoring it.

---

## `** (exit) no process` when calling `current/1`

**Error / symptom:**

```
** (exit) no process: the process is not alive or there's no process currently associated with the given name
```

**Root cause:**

The Registry GenServer for that secret has exited. This can happen if the source returned a permanent error (`:enoent`, `:not_found`, `:forbidden`, etc.) on `init/1` or a subsequent `load/1`, causing the process to stop.

**Fix:**

1. Check your application logs for the Logger warning or error that preceded the crash.
2. Look for permanent error reasons from your source. For `Source.File`, the most common cause is a missing or inaccessible file.
3. For `Source.Vault.KvV2`, check for a 403 (wrong permissions) or 404 (wrong path).
4. After fixing the root cause, `register/2` the secret again.

**Prevention:**

Monitor the `[:rotating_secrets, :degraded]` and `[:rotating_secrets, :state_change]` telemetry events to detect process failures before callers start receiving exits.

---

## Secret never refreshes (stuck in Valid state)

**Error / symptom:**

`Secret.meta/1` shows an old version or timestamp. The secret does not update even after the external value changes.

**Root cause:**

If the source does not return `:ttl_seconds` in meta, the Registry uses `:fallback_interval_ms` (default 60 000 ms). If the fallback interval is long and the source is not push-driven, updates are delayed.

**Fix:**

1. Check what your source returns in the meta map: `RotatingSecrets.Secret.meta(secret)`.
2. If `:ttl_seconds` is missing, either configure the source to return it, or lower `:fallback_interval_ms`:
   ```elixir
   RotatingSecrets.register(:my_secret,
     source: MySource,
     source_opts: [...],
     fallback_interval_ms: 10_000
   )
   ```
3. For `Source.File`, ensure `file_system` is included in your dependencies and that inotify works in your environment (see also: "Source.File not picking up changes" below).

**Prevention:**

Always return `:ttl_seconds` from your source's `load/1` when the external system provides an expiry.

---

## `Source.File` not picking up changes (wrong watch mode)

**Error / symptom:**

A file-based secret does not refresh when the file on disk changes. The Registry remains on the old value until the fallback interval fires.

**Root cause:**

One of the following:

- The `file_system` dependency is missing, so inotify-based watching is not available.
- The file was written in-place (`write(2)`) rather than via atomic rename. `Source.File` watches the parent directory for `moved_to` / `create` events; in-place writes may not generate those events on all inotify configurations.
- The parent directory itself was replaced (e.g., a Kubernetes secret volume mount), which removes the inotify watch.

**Fix:**

1. Add `{:file_system, "~> 1.1"}` to your dependencies and run `mix deps.get`.
2. Ensure the writer uses an atomic rename pattern:
   ```bash
   echo -n "new-value" > /run/secrets/db_password.tmp
   mv /run/secrets/db_password.tmp /run/secrets/db_password
   ```
3. For Kubernetes mounted secrets, set a non-zero `:fallback_interval_ms` as a backstop because directory replace events may be unreliable.
4. Verify the watch is active by checking `[:rotating_secrets, :state_change]` telemetry events after modifying the file.

**Prevention:**

Use atomic rename in all secret-rotation scripts. Set `fallback_interval_ms` to a reasonable value (30 000–60 000 ms) as a backstop for environments where inotify is unreliable.

---

## `Source.Env` emitting dev warnings in production

**Error / symptom:**

Production logs contain:

```
[warning] RotatingSecrets.Source.Env: reading secret from environment variable — not recommended for production
```

The `[:rotating_secrets, :dev_source_in_use]` telemetry event fires on startup.

**Root cause:**

`Source.Env` is configured in the production environment. It always emits this warning by design.

**Fix:**

Replace `Source.Env` with `Source.File` or `Source.Vault.KvV2` in production:

```elixir
# config/runtime.exs
source =
  if config_env() == :prod do
    RotatingSecrets.Source.File
  else
    RotatingSecrets.Source.Env
  end

config :my_app, secret_source: source
```

**Prevention:**

Never use `Source.Env` outside of `:dev` and `:test` environments. Guard all `Source.Env` registrations behind `config_env() in [:dev, :test]`.

---

## Vault 403 on `load/1`

**Error / symptom:**

The Registry process stops shortly after startup. Logs show a permanent failure with reason `:forbidden`.

**Root cause:**

The Vault token does not have `read` capability on the secret path.

**Fix:**

1. Verify the policy attached to your token:
   ```bash
   vault token lookup <token>
   vault policy read <policy-name>
   ```
2. Ensure the policy includes `capabilities = ["read"]` for the path:
   ```hcl
   path "secret/data/myapp/db" {
     capabilities = ["read"]
   }
   ```
3. Update and re-apply the policy, then generate a new token if needed.

**Prevention:**

Test the token with `vault kv get` before deploying. Use Vault's built-in policy simulation (`vault policy check`) to verify access.

---

## Vault 404 on `load/1`

**Error / symptom:**

The Registry process stops shortly after startup. Logs show a permanent failure with reason `:not_found`.

**Root cause:**

The secret path does not exist in the KV store, or the mount path is wrong.

**Fix:**

1. Verify the secret exists:
   ```bash
   vault kv get secret/myapp/db
   ```
2. Check the `:mount` and `:path` options in `source_opts`. The mount and path are separate options in `Source.Vault.KvV2` — do not combine them into `:path`.
3. If the secret was deleted, recreate it:
   ```bash
   vault kv put secret/myapp/db password=s3cr3t
   ```

**Prevention:**

Automate infrastructure-as-code for Vault secrets. Confirm paths in a staging environment before deploying to production.

---

## `{:error, :vault_rate_limited}`

**Error / symptom:**

The Registry enters exponential backoff with reason `:vault_rate_limited`. Logs show repeated transient failures.

**Root cause:**

Vault or OpenBao is returning HTTP 429 Too Many Requests. This can happen when many processes register simultaneously, or when the `:fallback_interval_ms` is very short and many nodes poll at the same time.

**Fix:**

1. Increase `:fallback_interval_ms` to reduce polling frequency.
2. Stagger registrations across nodes using a small `Process.sleep/1` jitter at startup.
3. If the Vault instance is under-resourced, scale it or check for other high-frequency clients.
4. The Registry retries with exponential backoff automatically; given time it will succeed.

**Prevention:**

Use `:ttl_seconds` in custom_metadata so the Registry schedules refreshes based on Vault's actual lease duration rather than a polling timer.

---

## `mix deps.get` fails in Nix sandbox

**Error / symptom:**

```
** (Mix.Error) Could not fetch packages from https://hex.pm
```

Or the build fails because `file_system` cannot find inotify headers.

**Root cause:**

Nix sandbox mode blocks outbound network access and may not expose inotify headers on the build PATH.

**Fix:**

1. Add `fetchHex` calls for your Hex packages to your Nix derivation:
   ```nix
   {file_system_src, ...}: buildMix {
     mixNixDeps = {
       file_system = beamPackages.fetchHex {
         pkg = "file_system"; version = "1.0.0";
         sha256 = "sha256-...";
       };
     };
   }
   ```
2. For inotify support, ensure `inotify-tools` or the kernel headers are in `buildInputs`.
3. Alternatively, use a `--no-network` build script that pre-downloads deps into a Hex cache before entering the sandbox.

**Prevention:**

Use `mix2nix` or `mix_to_nix` to generate a reproducible deps lock compatible with Nix.

---

## Dialyzer warning on `Secret.expose/1` return type

**Error / symptom:**

```
Function expose/1 will never return since the success typing is binary() but the spec says binary()
```

Or a spurious warning that the return type of `expose/1` is not `binary()`.

**Root cause:**

Dialyzer is resolving the opaque `Secret.t()` type from outside the module boundary. The opaque type prevents Dialyzer from seeing the internal struct, which can cause it to infer an overly restrictive type for `expose/1`.

**Fix:**

1. Ensure your project has an up-to-date PLT that includes the `rotating_secrets` app:
   ```bash
   mix dialyzer --plt
   ```
2. If the warning persists, add a type annotation at the call site:
   ```elixir
   @spec get_password() :: binary()
   def get_password do
     {:ok, secret} = RotatingSecrets.current(:db_password)
     RotatingSecrets.Secret.expose(secret)
   end
   ```
3. You can also suppress the specific warning with a `@dialyzer` attribute if the annotation is not practical.

**Prevention:**

Include `rotating_secrets` in your PLT and keep the PLT up to date when upgrading the library.

---

## Rotation notification never received (subscriber registered after rotation)

**Error / symptom:**

A subscriber process calls `subscribe/1` and then waits with `assert_receive`, but no `{:rotating_secret_rotated, ...}` message arrives, even though the secret has rotated.

**Root cause:**

The secret rotated between the `current/1` call and the `subscribe/1` call. The subscription was registered after the rotation event was delivered, so it was not included in the broadcast.

**Fix:**

Always subscribe **before** reading the current value:

```elixir
# Correct
{:ok, sub_ref} = RotatingSecrets.subscribe(:db_password)
{:ok, secret} = RotatingSecrets.current(:db_password)

# Incorrect — race window between current and subscribe
{:ok, secret} = RotatingSecrets.current(:db_password)
{:ok, sub_ref} = RotatingSecrets.subscribe(:db_password)
```

After subscribing, the current value obtained from `current/1` is the baseline. Any subsequent rotation will deliver a notification to the subscriber.

**Prevention:**

Establish the subscribe-before-read pattern in a wrapper function and document it in your codebase.

---

## `Source.Memory.update/2` returns `{:error, :not_found}`

**Error / symptom:**

```elixir
{:error, :not_found} = RotatingSecrets.Source.Memory.update(:my_secret, "new-value")
```

**Root cause:**

The `Source.Memory` Agent is not started, or was started under a different name. Each `Source.Memory` instance is registered in `RotatingSecrets.ProcessRegistry` under the `:name` given in `source_opts`. If registration failed or the `ProcessRegistry` itself is not running, `update/2` cannot find the Agent.

**Fix:**

1. Ensure `RotatingSecrets.Supervisor` was started before calling `register/2`.
2. Confirm the `:name` in `source_opts` matches the atom used in `update/2`:
   ```elixir
   RotatingSecrets.register(:my_secret,
     source: RotatingSecrets.Source.Memory,
     source_opts: [name: :my_secret, initial_value: "initial"]
   )
   RotatingSecrets.Source.Memory.update(:my_secret, "new-value")  # same atom
   ```
3. If the supervisor was restarted mid-test (e.g., due to a previous test failure), the Agent may have been cleaned up. Use `start_supervised!` in an ExUnit `setup` block to ensure a fresh supervisor for each test.

**Prevention:**

Use `async: false` in tests that use `Source.Memory` to avoid name conflicts between concurrent test processes.

---

## Supervisor fails to start (`ProcessRegistry already started`)

**Error / symptom:**

```
** (EXIT) {:already_started, #PID<0.123.0>}
```

`RotatingSecrets.Supervisor` fails to start because `RotatingSecrets.ProcessRegistry` is already registered.

**Root cause:**

`RotatingSecrets.Supervisor` is started twice in the same node. This can happen if it appears in both the application supervision tree and a test's `start_supervised!` call.

**Fix:**

1. Do not add `RotatingSecrets.Supervisor` to the application supervision tree during tests. Remove it from the children list in test environments, or guard it with `config_env()`:
   ```elixir
   children =
     if Application.get_env(:my_app, :start_rotating_secrets, true) do
       [RotatingSecrets.Supervisor | other_children]
     else
       other_children
     end
   ```
2. In `config/test.exs`:
   ```elixir
   config :my_app, start_rotating_secrets: false
   ```
3. Then in each test that needs it: `start_supervised!(RotatingSecrets.Supervisor)`.

**Prevention:**

Follow the pattern of not starting external supervisor trees in the application during tests. Let each test start what it needs.

---

## Horde: secret registered on node A not visible on node B

**Error / symptom:**

`RotatingSecrets.current(:my_secret)` returns `{:error, :not_registered}` on node B even though the secret was registered on node A.

**Root cause:**

Distributed process registration via Horde is not yet implemented. In the current release, each node has an independent `ProcessRegistry`. A secret registered on node A exists only on node A.

**Fix:**

Register the secret on all nodes as part of application startup. Each node loads the secret independently from the source:

```elixir
# Called in application.ex start/2 on every node
RotatingSecrets.register(:my_secret,
  source: RotatingSecrets.Source.Vault.KvV2,
  source_opts: [...]
)
```

Use `RotatingSecrets.cluster_status/1` to verify that all nodes have loaded the secret:

```elixir
RotatingSecrets.cluster_status(:my_secret)
# All nodes should show {:ok, version, meta}
```

**Prevention:**

Design startup sequences so all nodes register the secrets they need. Do not assume that registration on one node is globally visible.

---

## ExUnit test intermittently fails because rotation fires before assert

**Error / symptom:**

A test that calls `Source.Memory.update/2` and then `assert_receive` occasionally times out or asserts the wrong value, especially when the test suite runs with high parallelism.

**Root cause:**

The rotation notification is delivered asynchronously. If `assert_receive` uses a timeout of 0 ms, it fires before the Registry has processed the update. Alternatively, a previous rotation from a concurrent test is being received instead of the expected one.

**Fix:**

1. Use a non-zero timeout in `assert_receive` (at least 200 ms for local processes):
   ```elixir
   assert_receive {:rotating_secret_rotated, ^sub_ref, :my_secret, _version}, 500
   ```
2. Match on `^sub_ref` to ensure you receive the message from your specific subscription, not from a concurrent test's subscription:
   ```elixir
   {:ok, sub_ref} = RotatingSecrets.subscribe(:my_secret)
   # ... trigger rotation ...
   assert_receive {:rotating_secret_rotated, ^sub_ref, :my_secret, _version}, 500
   ```
3. Use `async: false` for tests that use `Source.Memory` to eliminate cross-test interference.
4. If the test exercises timing-sensitive backoff or TTL behaviour, pass short `min_backoff_ms` and `max_backoff_ms` values to `register/2` directly.

**Prevention:**

Always pin `sub_ref` in `assert_receive` patterns. Use `async: false` for any test that uses named global state such as `Source.Memory` agents.
