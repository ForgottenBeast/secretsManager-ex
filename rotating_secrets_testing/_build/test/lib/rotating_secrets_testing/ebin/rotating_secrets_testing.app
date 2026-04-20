{application,rotating_secrets_testing,
             [{modules,['Elixir.RotatingSecrets.Source.Controllable',
                        'Elixir.RotatingSecrets.Testing',
                        'Elixir.RotatingSecrets.Testing.Supervisor']},
              {optional_applications,[]},
              {applications,[kernel,stdlib,elixir,logger,rotating_secrets]},
              {description,"ExUnit helpers and a controllable test source for rotating_secrets"},
              {registered,[]},
              {vsn,"0.1.0"}]}.
