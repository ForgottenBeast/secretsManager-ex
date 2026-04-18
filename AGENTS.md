# Elixir Project — Agent Guide

## Framework: Ash

This project uses the [Ash Framework](https://hexdocs.pm/ash) as the primary abstraction layer for resources, APIs, UI, and MCP surfaces.

### Resources
- All domain entities are Ash resources (`use Ash.Resource`)
- Group related resources under a domain module (`use Ash.Domain`)
- Actions (`:create`, `:read`, `:update`, `:destroy`) are declared explicitly in the resource; avoid raw Ecto queries
- Changesets and queries go through `Ash.changeset/2`, `Ash.Query.for_read/3`, never bypassed
- Calculations and aggregates belong on the resource, not in controller/context logic
- Authorization: use Ash policies (`use Ash.Policy.Authorizer`) — no hand-rolled permission checks

### API layer (AshJsonApi / AshGraphql)
- REST endpoints: `use AshJsonApi.Resource` + `use AshJsonApi.Router` — do not write Phoenix controllers for CRUD
- GraphQL: `use AshGraphql.Resource` — declare queries/mutations on the resource, not in a separate schema file
- All external API surfaces must go through an Ash resource action; no direct context calls from router plugs

### MCP
- MCP tool definitions are Ash actions exposed via the MCP adapter
- Each MCP tool maps 1:1 to a named Ash action; keep tool names matching action names for traceability
- Input validation happens in the Ash changeset, not in MCP handler code

### UI (AshPhoenix / LiveView)
- Forms use `AshPhoenix.Form` — not `Phoenix.HTML.Form` or `Ecto.Changeset` directly
- LiveView assigns drive from `Ash.read!` / `Ash.get!`; avoid holding raw structs from outside Ash
- Error rendering: use `AshPhoenix.Form.errors/1`, not manual changeset traversal

---

## Observability: observlib-ex

This project uses [observlib-ex](https://github.com/ForgottenBeast/observlib-ex) for all observability setup (structured logging, telemetry, tracing).

Rules:
- Call `Observlib.setup(config)` in your `Application.start/2`, before starting the supervision tree
- Observability config lives in `config/runtime.exs` under the `:observlib` key — do not configure `:logger`, `:telemetry`, or `:opentelemetry` directly
- Instrument public functions with `:telemetry.span/3` or the `Observlib.span/2` helper macro
- Log with structured metadata: `Logger.info("msg", key: value)` — never bare string concatenation in log calls
- Metrics: emit via `:telemetry.execute/3`; define measurements in a dedicated `MyApp.Telemetry` module that attaches handlers at startup through observlib

```elixir
# In Application.start/2
Observlib.setup(Application.fetch_env!(:my_app, :observlib))
```

---

## Testing

### Property-based tests: StreamData

Property tests use [StreamData](https://hexdocs.pm/stream_data) (`use ExUnitProperties`).

Rules:
- Every non-trivial pure function or Ash changeset validation must have at least one `property` test
- `ExUnit.Case` `test` blocks are for specific edge cases and regression tests; `property` blocks cover general behaviour
- Use `StreamData.filter/2` to discard invalid inputs rather than asserting inside a filter
- Custom generators belong in a `MyApp.Generators` module, not inline in test files
- Put property tests in `test/<context>/<module>_properties_test.exs`, separate from unit tests

```elixir
defmodule MyApp.MyModulePropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "encode/decode round-trip" do
    check all input <- string(:alphanumeric, min_length: 1) do
      assert MyApp.decode(MyApp.encode(input)) == input
    end
  end
end
```

### Fault injection and resilience: Snabbkaffe

Resilience and fault-injection tests use [Snabbkaffe](https://github.com/kafka4beam/snabbkaffe).

Rules:
- Use `snabbkaffe` for tests that verify behaviour under process crashes, message reordering, or injected faults
- Fault injection points are declared with `:snabbkaffe.inject_crash/2` or the `?tp` trace-point macro — never use `:timer.sleep` as a proxy for timing-sensitive assertions
- Trace-point assertions use `?block_until` / `snabbkaffe:block_until/2` with explicit timeout and retry budget
- Resilience tests live in `test/<context>/<module>_resilience_test.exs`
- Tag resilience tests with `@tag :resilience` so they can be run or excluded separately: `mix test --only resilience`
- Every supervised process that can crash must have a corresponding snabbkaffe resilience test covering restart behaviour

```elixir
defmodule MyApp.WorkerResilienceTest do
  use ExUnit.Case
  import Snabbkaffe

  @tag :resilience
  test "worker restarts and resumes after crash" do
    :snabbkaffe.start_trace()
    pid = start_supervised!(MyApp.Worker)
    :snabbkaffe.inject_crash(pid, :kill)
    assert_async(fn ->
      {ok, _} = :snabbkaffe.block_until(
        %{kind: :worker_started},
        _timeout = 1000,
        _backoff = 100
      )
    end)
    :snabbkaffe.stop()
  end
end
```

---

## mix.exs requirements

Ensure these dependencies are present:

```elixir
defp deps do
  [
    # Ash core + extensions
    {:ash, "~> 3.0"},
    {:ash_json_api, "~> 1.0"},
    {:ash_graphql, "~> 1.0"},
    {:ash_phoenix, "~> 2.0"},

    # Observability
    {:observlib, github: "ForgottenBeast/observlib-ex"},

    # Testing
    {:stream_data, "~> 1.0", only: [:test, :dev]},
    {:snabbkaffe, "~> 1.0", only: :test},
  ]
end
```

---

## Project layout

```
lib/
├── my_app/
│   ├── application.ex          # Application.start/2, Observlib.setup/1
│   ├── telemetry.ex            # :telemetry handler attachment
│   ├── domain.ex               # Ash.Domain grouping resources
│   ├── resources/
│   │   └── <entity>.ex         # Ash.Resource definitions
│   ├── api/
│   │   └── router.ex           # AshJsonApi.Router
│   └── generators.ex           # StreamData generators for tests
test/
├── <context>/
│   ├── <module>_test.exs           # Unit / integration tests
│   ├── <module>_properties_test.exs # StreamData property tests
│   └── <module>_resilience_test.exs # Snabbkaffe resilience tests
config/
├── config.exs
└── runtime.exs                 # :observlib runtime config
docs/
├── book.toml
├── plans/                      # Approved epic plans
└── src/
    └── SUMMARY.md
```

---

## Build outputs

- `nix build .#default` — OTP release
- `nix build .#doc` — mdBook from `docs/`
- `mix docs` — ExDoc API docs

## mix2nix workflow

After adding or updating dependencies:
```bash
mix deps.get
mix2nix > mix.nix
git add mix.nix
```

## See also

- Global rules: `~/.AGENTS.md`
- Ash docs: https://hexdocs.pm/ash
- observlib-ex: https://github.com/ForgottenBeast/observlib-ex
- StreamData: https://hexdocs.pm/stream_data
- Snabbkaffe: https://github.com/kafka4beam/snabbkaffe
