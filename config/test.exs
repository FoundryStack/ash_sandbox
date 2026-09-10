import Config

# Fixed key, so a test that writes a credential and one that reads it agree
# across runs. Never used outside `:test` -- `config/runtime.exs` in a
# consuming host raises rather than default this in `:prod` (003 T036).
config :ash_sandbox, AshSandbox.EncryptedSecret,
  key: "i6Sg1FnEGhBjbEhsbJeNTwnKJdFIab25N8B1g3bpYnI="
