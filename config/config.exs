import Config

# Required by `ash` (as of the version this package's tests pulled at
# extraction time) for any resource declaring a `:string`/`:ci_string`
# `min_length`/`max_length` constraint or a `string_length` validation --
# `test/support/host_app.ex`'s templated resources do. `:codepoints` matches
# how the SQL data layers this library's templates target count length, so
# validation agrees with what the database enforces.
config :ash, default_string_length_count: :codepoints

import_config "#{config_env()}.exs"
