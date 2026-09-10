defmodule TourDocTest do
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
      |> Ash.update(authorize?: false, atomic_upgrade?: false)

    {:ok, sandbox} =
      sandbox
      |> Ash.Changeset.for_update(:mark_starting, %{})
      |> Ash.update(authorize?: false, atomic_upgrade?: false)

    {:ok, sandbox} =
      sandbox
      |> Ash.Changeset.for_update(:mark_running, %{address: "127.0.0.1:8123"})
      |> Ash.update(authorize?: false, atomic_upgrade?: false)

    assert sandbox.state == :running

    assert {:error, _} =
             sandbox
             |> Ash.Changeset.for_update(:mark_running, %{})
             |> Ash.update(authorize?: false, atomic_upgrade?: false)

    {:ok, failed} =
      sandbox
      |> Ash.Changeset.for_update(:mark_failed, %{
        failure_reason: :template_missing,
        failure_detail: "no template elixir-1.18 for stack :elixir"
      })
      |> Ash.update(authorize?: false, atomic_upgrade?: false)

    assert failed.failure_reason == :template_missing

    assert {:error, _} =
             sandbox
             |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: :something_went_wrong})
             |> Ash.update(authorize?: false, atomic_upgrade?: false)
  end
end
