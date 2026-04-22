Code.require_file("support/openbao_helper.ex", __DIR__)
Code.require_file("support/source_fault.ex", __DIR__)

openbao_available =
  System.get_env("OPENBAO_SKIP") != "1" and
  (System.find_executable("bao") != nil or System.get_env("OPENBAO_BIN") != nil)

if openbao_available do
  {:ok, _} = RotatingSecrets.Supervisor.start_link()
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
  ExUnit.configure(exclude: (ExUnit.configuration()[:exclude] || []) ++ [:openbao])
  IO.puts("[OpenBaoHelper] bao binary not found or OPENBAO_SKIP=1 — :openbao tests excluded")
end

Code.require_file("support/rust_consumer_helper.ex", __DIR__)

rust_available =
  System.get_env("RUST_CONSUMER_SKIP") != "1" and
  (fn ->
    bin = System.get_env("RUST_CONSUMER_BIN", "")
    bin != "" and File.exists?(bin)
  end).()

unless rust_available do
  ExUnit.configure(exclude: (ExUnit.configuration()[:exclude] || []) ++ [:cross_lang])
  IO.puts("[RustConsumerHelper] Rust binary not found or RUST_CONSUMER_SKIP=1 — :cross_lang tests excluded")
end

# To run :openbao_db tests locally (requires nix develop):
#   ./scripts/run_db_tests.sh
# For :cross_lang_db tests too (also requires RUST_CONSUMER_BIN):
#   RUST_CONSUMER_BIN=/path/to/http_server ./scripts/run_db_tests.sh
# Or, if PostgreSQL is already running:
#   PG_AVAILABLE=1 mix test.db
pg_available = System.get_env("PG_AVAILABLE") == "1"

unless pg_available do
  ExUnit.configure(exclude: (ExUnit.configuration()[:exclude] || []) ++ [:openbao_db, :cross_lang_db])
  IO.puts("[test_helper] PostgreSQL not available — :openbao_db and :cross_lang_db tests excluded")
end

ExUnit.start()
