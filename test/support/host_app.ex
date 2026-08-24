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
    resource AshSandbox.HostApp.BareRegistry
    resource AshSandbox.HostApp.RefusingRegistry
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
    project_resource: AshSandbox.HostApp.Project
end

defmodule AshSandbox.HostApp.SandboxRegistry do
  @moduledoc """
  The one-line module a host writes. This is the whole integration surface.
  """
  use AshSandbox.RegistryTemplate,
    data_layer: Ash.DataLayer.Ets,
    domain: AshSandbox.HostApp.Sandboxes,
    table: "host_sandboxes"

  sandbox do
    mechanism(AshSandbox.HostApp.NullMechanism)
    run_policy(AshSandbox.HostApp.AlwaysAllow)
    cpu_limit(500)
    memory_limit_mb(256)
    disk_quota_mb(1024)
    idle_timeout_seconds(900)
  end
end

defmodule AshSandbox.HostApp.AlwaysAllow do
  @moduledoc "A host that has no lifecycle opinion -- the simplest legal policy."
  @behaviour AshSandbox.RunPolicy

  @impl true
  def may_run?(_sandbox), do: :ok
end

defmodule AshSandbox.HostApp.RefuseAll do
  @moduledoc "A host that always refuses, with a reason only it understands."
  @behaviour AshSandbox.RunPolicy

  @impl true
  def may_run?(_sandbox), do: {:error, {:owner_delinquent, "invoice 42 unpaid"}}
end

defmodule AshSandbox.HostApp.NullMechanism do
  @moduledoc "A mechanism that does nothing, so the DSL has something valid to name."
  @behaviour ExSandbox.Mechanism

  @impl true
  def required_capabilities, do: []

  @impl true
  def provision(sandbox), do: {:ok, sandbox}

  @impl true
  def start(sandbox), do: {:ok, sandbox}

  @impl true
  def stop(sandbox), do: {:ok, sandbox}

  @impl true
  def destroy(_sandbox), do: :ok

  @impl true
  def status(_sandbox), do: {:ok, :running}

  @impl true
  def list_running, do: {:ok, []}

  @impl true
  def usage(_sandbox), do: {:ok, %{}}
end

defmodule AshSandbox.HostApp.RefusingRegistry do
  @moduledoc """
  A registry whose host has decided its sandboxes may not run (012 T042).

  Same shape as `SandboxRegistry`, different run policy -- the plug must refuse
  a hostname that resolves perfectly well but whose owner the host has said no
  about.
  """
  use AshSandbox.RegistryTemplate,
    data_layer: Ash.DataLayer.Ets,
    domain: AshSandbox.HostApp.Sandboxes,
    table: "refusing_sandboxes"

  sandbox do
    mechanism(AshSandbox.HostApp.NullMechanism)
    run_policy(AshSandbox.HostApp.RefuseAll)
  end
end

defmodule AshSandbox.HostApp.BareRegistry do
  @moduledoc "A host that declares no sandbox options at all -- the minimum call site."
  use AshSandbox.RegistryTemplate,
    data_layer: Ash.DataLayer.Ets,
    domain: AshSandbox.HostApp.Sandboxes,
    table: "bare_sandboxes"
end

defmodule AshSandbox.HostApp.ExplodingRegistry do
  @moduledoc """
  A registry whose read always raises (012 T042).

  Stands in for the database blip in `006` R4's last row. The plug must refuse
  on it -- authorizing on a lookup failure would let an attacker who can induce
  failures reach arbitrary sandboxes.
  """
  def to_sandbox(record, context \\ nil),
    do: AshSandbox.HostApp.SandboxRegistry.to_sandbox(record, context)
end
