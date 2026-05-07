unless System.get_env("SCW_INTEGRATION") == "1" do
  current_exclude = ExUnit.configuration()[:exclude] || []
  ExUnit.configure(exclude: [:scw_integration | current_exclude])
end

ExUnit.start()
