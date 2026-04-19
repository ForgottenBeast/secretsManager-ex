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
