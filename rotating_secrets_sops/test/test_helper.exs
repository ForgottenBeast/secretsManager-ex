sops_available =
  System.get_env("SOPS_SKIP") != "1" and
    System.find_executable("sops") != nil and
    System.find_executable("age-keygen") != nil

unless sops_available do
  ExUnit.configure(exclude: (ExUnit.configuration()[:exclude] || []) ++ [:sops])
  IO.puts("[test_helper] sops or age-keygen not found, or SOPS_SKIP=1 — :sops tests excluded")
end

ExUnit.start()
