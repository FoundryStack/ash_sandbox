defmodule AshSandbox.ExtensionsForwardedTest.Noop do
  @moduledoc false
  use Spark.Dsl.Extension, sections: []
end

defmodule AshSandbox.ExtensionsForwardedTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshSandbox.ExtensionsForwardedTest.Project
    resource AshSandbox.ExtensionsForwardedTest.Environment
    resource AshSandbox.ExtensionsForwardedTest.OperationRecord
    resource AshSandbox.ExtensionsForwardedTest.Credential
  end
end

defmodule AshSandbox.ExtensionsForwardedTest.Project do
  @moduledoc false
  use AshSandbox.ProjectTemplate,
    data_layer: Ash.DataLayer.Ets,
    domain: AshSandbox.ExtensionsForwardedTest.Domain,
    table: "ext_projects",
    extensions: [AshSandbox.ExtensionsForwardedTest.Noop]
end

defmodule AshSandbox.ExtensionsForwardedTest.Environment do
  @moduledoc false
  use AshSandbox.EnvironmentTemplate,
    data_layer: Ash.DataLayer.Ets,
    domain: AshSandbox.ExtensionsForwardedTest.Domain,
    table: "ext_environments",
    project_resource: AshSandbox.ExtensionsForwardedTest.Project,
    registry_resource: AshSandbox.HostApp.SandboxRegistry,
    extensions: [AshSandbox.ExtensionsForwardedTest.Noop]
end

defmodule AshSandbox.ExtensionsForwardedTest.OperationRecord do
  @moduledoc false
  use AshSandbox.OperationRecordTemplate,
    data_layer: Ash.DataLayer.Ets,
    domain: AshSandbox.ExtensionsForwardedTest.Domain,
    table: "ext_operation_records",
    extensions: [AshSandbox.ExtensionsForwardedTest.Noop]
end

defmodule AshSandbox.ExtensionsForwardedTest.Credential do
  @moduledoc false
  use AshSandbox.SandboxCredentialTemplate,
    data_layer: Ash.DataLayer.Ets,
    domain: AshSandbox.ExtensionsForwardedTest.Domain,
    table: "ext_credentials",
    sandbox_resource: AshSandbox.HostApp.SandboxRegistry,
    extensions: [AshSandbox.ExtensionsForwardedTest.Noop]
end

defmodule AshSandbox.ExtensionsForwardedTest do
  @moduledoc """
  Every resource template forwards `extensions:` to `use Ash.Resource`, as
  `RegistryTemplate` does; unset, a binding has the template's own.
  """
  use ExUnit.Case, async: true

  alias AshSandbox.ExtensionsForwardedTest, as: T

  for resource <- [T.Project, T.Environment, T.OperationRecord, T.Credential] do
    test "#{inspect(resource)} carries the extension its binding passed" do
      assert T.Noop in Spark.extensions(unquote(resource))
    end
  end

  test "a binding that passes none carries no extra extension" do
    refute T.Noop in Spark.extensions(AshSandbox.HostApp.Project)
    refute T.Noop in Spark.extensions(AshSandbox.HostApp.Environment)
  end
end
