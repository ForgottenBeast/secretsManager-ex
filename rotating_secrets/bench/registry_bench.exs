# Benchmark suite for RotatingSecrets registry read path.
#
# Run with:
#   mix run bench/registry_bench.exs
#
# Or via the mix alias:
#   mix bench

# ---------------------------------------------------------------------------
# Start the supervision tree
# ---------------------------------------------------------------------------

{:ok, _sup} = RotatingSecrets.Supervisor.start_link()

# ---------------------------------------------------------------------------
# Helper: register N secrets and return their names
# ---------------------------------------------------------------------------

defmodule BenchHelper do
  def register_secrets(count, prefix) do
    for i <- 1..count do
      name = :"bench_#{prefix}_#{i}"

      {:ok, _pid} =
        RotatingSecrets.register(name,
          source: RotatingSecrets.Source.Memory,
          source_opts: [name: name, initial_value: "secret-value-#{i}"],
          fallback_interval_ms: 86_400_000
        )

      name
    end
  end

  def deregister_secrets(names) do
    Enum.each(names, &RotatingSecrets.deregister/1)
  end
end

# ---------------------------------------------------------------------------
# Pre-register secret pools for each scenario
# ---------------------------------------------------------------------------

names_1  = BenchHelper.register_secrets(1,  "s1")
names_10 = BenchHelper.register_secrets(10, "s10")
names_50 = BenchHelper.register_secrets(50, "s50")

# Pick a stable single name for the hot-path benchmarks
hot_name   = hd(names_1)
hot_name10 = hd(names_10)
hot_name50 = hd(names_50)

# ---------------------------------------------------------------------------
# Benchmark scenarios
# ---------------------------------------------------------------------------

Benchee.run(
  %{
    # -----------------------------------------------------------------------
    # current/1 hot path — most important metric
    # -----------------------------------------------------------------------
    "current/1 — 1 secret registered" => fn ->
      {:ok, _secret} = RotatingSecrets.current(hot_name)
    end,

    "current/1 — 10 secrets registered" => fn ->
      {:ok, _secret} = RotatingSecrets.current(hot_name10)
    end,

    "current/1 — 50 secrets registered" => fn ->
      {:ok, _secret} = RotatingSecrets.current(hot_name50)
    end,

    # -----------------------------------------------------------------------
    # with_secret/2 acquire + release cycle
    # -----------------------------------------------------------------------
    "with_secret/2 — 1 secret registered" => fn ->
      {:ok, _result} = RotatingSecrets.with_secret(hot_name, fn _secret -> :ok end)
    end,

    "with_secret/2 — 10 secrets registered" => fn ->
      {:ok, _result} = RotatingSecrets.with_secret(hot_name10, fn _secret -> :ok end)
    end,

    "with_secret/2 — 50 secrets registered" => fn ->
      {:ok, _result} = RotatingSecrets.with_secret(hot_name50, fn _secret -> :ok end)
    end
  },
  time: 5,
  warmup: 2,
  print: [fast_warning: false]
)

# ---------------------------------------------------------------------------
# Clean up
# ---------------------------------------------------------------------------

BenchHelper.deregister_secrets(names_1)
BenchHelper.deregister_secrets(names_10)
BenchHelper.deregister_secrets(names_50)

IO.puts("\nBenchmark complete.")
