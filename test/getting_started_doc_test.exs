defmodule GettingStartedDocTest do
  @moduledoc """
  `docs/getting-started.md`, executed.

  A tutorial is a promise that the reader can type the page and get the stated
  result, and prose cannot keep that promise on its own. Every step below is
  the page's own code with the host modules swapped for the ones
  `test/support/host_app.ex` already declares -- so a rename, a changed
  argument name or a new required attribute fails here rather than on a
  reader's first attempt.

  MEASURED while writing the page, and each of these was a sentence that would
  otherwise have shipped wrong: `idle_timeout_seconds` is required on an
  `on_demand` environment; `:mark_failed` takes `reason`/`detail` as arguments,
  not the attribute names it stores them under; and `:mark_running` validates
  the RECORD's address, so the refusal needs a sandbox that never had one.

  It is also, incidentally, the only coverage in this library of a lifecycle
  update against a non-PostgreSQL data layer -- the gap that let every `mark_*`
  action raise `MustBeAtomic` on ETS. See
  `AshSandbox.Internal.DataLayerSection.require_atomic/1`.
  """
  use ExUnit.Case, async: false
  alias AshSandbox.HostApp

  test "the getting-started script runs as written" do
    {:ok, project} =
      HostApp.Project
      |> Ash.Changeset.for_create(:create, %{owner_ref: "acct_42", name: "checkout"})
      |> Ash.create(authorize?: false)

    {:ok, environment} =
      HostApp.Environment
      |> Ash.Changeset.for_create(:create, %{
        project_id: project.id,
        name: "preview",
        target_stack: :elixir,
        template_name: "elixir-1.18",
        purpose: :development,
        idle_timeout_seconds: 900,
        network_allowlist: ["api.stripe.com:443"]
      })
      |> Ash.create(authorize?: false)

    assert environment.owner_ref == "acct_42"

    {:ok, sandbox} =
      HostApp.SandboxRegistry
      |> Ash.Changeset.for_create(:provision, %{
        id: "sbx_01",
        owner_ref: project.owner_ref,
        environment_ref: environment.id,
        template_ref: "elixir-1.18",
        mechanism: :docker,
        cpu_limit: 2,
        memory_limit_mb: 2048
      })
      |> Ash.create(authorize?: false)

    assert sandbox.state == :provisioning

    {:ok, sandbox} =
      sandbox
      |> Ash.Changeset.for_update(:mark_provisioned, %{
        mechanism_ref: "docker://9f2c",
        address: "127.0.0.1:8123"
      })
      |> Ash.update(authorize?: false)

    {:ok, sandbox} =
      sandbox
      |> Ash.Changeset.for_update(:mark_starting, %{})
      |> Ash.update(authorize?: false)

    {:ok, sandbox} =
      sandbox
      |> Ash.Changeset.for_update(:mark_running, %{address: "127.0.0.1:8123"})
      |> Ash.update(authorize?: false)

    assert sandbox.state == :running

    {:ok, addressless} =
      HostApp.SandboxRegistry
      |> Ash.Changeset.for_create(:provision, %{
        id: "sbx_02",
        owner_ref: project.owner_ref,
        environment_ref: "env_without_environment_row"
      })
      |> Ash.create(authorize?: false)

    assert {:error, _} =
             addressless
             |> Ash.Changeset.for_update(:mark_running, %{})
             |> Ash.update(authorize?: false)

    {:ok, failed} =
      sandbox
      |> Ash.Changeset.for_update(:mark_failed, %{
        reason: :template_missing,
        detail: "no template elixir-1.18 for stack :elixir"
      })
      |> Ash.update(authorize?: false)

    assert failed.failure_reason == :template_missing

    assert {:error, _} =
             sandbox
             |> Ash.Changeset.for_update(:mark_failed, %{reason: :something_went_wrong})
             |> Ash.update(authorize?: false)
  end
end
