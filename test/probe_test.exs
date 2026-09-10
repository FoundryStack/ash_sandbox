defmodule ProbeTest do
  use ExUnit.Case, async: false
  alias AshSandbox.HostApp

  test "which updates work on ETS" do
    {:ok, p} =
      HostApp.Project
      |> Ash.Changeset.for_create(:create, %{owner_ref: "o", name: "n"})
      |> Ash.create(authorize?: false)

    IO.inspect(
      p |> Ash.Changeset.for_update(:rename, %{name: "n2"}) |> Ash.update(authorize?: false),
      label: "project rename"
    )

    {:ok, e} =
      HostApp.Environment
      |> Ash.Changeset.for_create(:create, %{
        project_id: p.id,
        name: "preview",
        target_stack: :elixir,
        template_name: "t",
        idle_timeout_seconds: 900
      })
      |> Ash.create(authorize?: false)

    IO.inspect(
      e
      |> Ash.Changeset.for_update(:update, %{idle_timeout_seconds: 600})
      |> Ash.update(authorize?: false)
      |> then(&elem(&1, 0)),
      label: "environment update"
    )

    {:ok, s} =
      HostApp.SandboxRegistry
      |> Ash.Changeset.for_create(:provision, %{
        id: "sbx",
        owner_ref: "o",
        environment_ref: e.id
      })
      |> Ash.create(authorize?: false)

    for action <- [:mark_starting, :mark_stopping, :mark_destroyed] do
      res =
        s |> Ash.Changeset.for_update(action, %{}) |> Ash.update(authorize?: false) |> elem(0)

      IO.inspect(res, label: to_string(action))
    end
  end
end
