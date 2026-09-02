defmodule AshSandbox.HostApp do
  @moduledoc """
  A pretend host application (012 T016, T017).

  Stands in for the Story 1 consumer: someone with no connection to Axonn who
  supplies their own data layer, domain, and table. It uses `Ash.DataLayer.Ets`
  rather than AshPostgres precisely because `ash_sandbox` must not require a
  particular data layer — a test that could only be written against Postgres
  would not be testing `FR-009`.
  """
end

defmodule AshSandbox.HostApp.Sandboxes do
  @moduledoc "The host's own Ash domain."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshSandbox.HostApp.SandboxRegistry
    resource AshSandbox.HostApp.Project
    resource AshSandbox.HostApp.Environment
  end
end

defmodule AshSandbox.HostApp.Project do
  @moduledoc """
  The host's project resource, on ETS rather than AshPostgres.

  Its existence is the assertion: `ProjectTemplate` declares a unique identity,
  and a template that hardcoded the PostgreSQL treatment of one would refuse to
  compile here (`012-FR-009`).
  """
  use AshSandbox.ProjectTemplate,
    data_layer: Ash.DataLayer.Ets,
    domain: AshSandbox.HostApp.Sandboxes,
    table: "host_projects"
end

defmodule AshSandbox.HostApp.Environment do
  @moduledoc """
  The host's environment resource, on ETS, pointed at the host's own project.
  """
  use AshSandbox.EnvironmentTemplate,
    data_layer: Ash.DataLayer.Ets,
    domain: AshSandbox.HostApp.Sandboxes,
    table: "host_environments",
    project_resource: AshSandbox.HostApp.Project,
    registry_resource: AshSandbox.HostApp.SandboxRegistry
end

defmodule AshSandbox.HostApp.SandboxRegistry do
  @moduledoc """
  The one-line module a host writes. This is the whole integration surface.
  """
  use AshSandbox.RegistryTemplate,
    data_layer: Ash.DataLayer.Ets,
    domain: AshSandbox.HostApp.Sandboxes,
    table: "host_sandboxes"
end

# ⚠️ Six fixtures stood below here: `AlwaysAllow`, `RefuseAll`, `NullMechanism`,
# `RefusingRegistry`, `BareRegistry` and `ExplodingRegistry`. Each existed to
# give the withdrawn `sandbox do ... end` DSL something valid to name, or to
# give `AshSandbox.Plug` a registry that refused, declared nothing, or raised.
# With both withdrawn (R-12) none of them is reachable from a test.
#
# `SandboxRegistry` above is now the whole integration surface a host writes,
# which is what `012` T016 claimed it was.
