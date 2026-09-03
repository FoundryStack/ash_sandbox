defmodule AshSandbox.EnvironmentTemplateTest do
  @moduledoc """
  A host on ETS can bind `ProjectTemplate` and `EnvironmentTemplate` (012 T016,
  `FR-009`).

  ## Why an ETS host and not another Postgres one

  Both templates declare a unique identity, and Ash's `RequirePreCheckWith`
  verifier refuses to compile an identity a data layer cannot enforce natively.
  Before `pre_check_with` was derived from the data layer, this module could not
  be compiled at all — the failure was at compile time, so the whole test file
  was the assertion. It still is: a regression here does not produce a red test,
  it produces a build that does not start.

  The creates below then prove the derived option is *live* rather than merely
  accepted — on ETS the identity has nothing but the pre-check behind it, so a
  duplicate that gets through means the constraint is not being enforced.
  """
  use ExUnit.Case, async: false

  alias AshSandbox.HostApp.Environment
  alias AshSandbox.HostApp.Project

  defp project!(owner_ref \\ "owner-a", name \\ nil) do
    Ash.create!(
      Project,
      %{owner_ref: owner_ref, name: name || unique("proj")},
      action: :create,
      authorize?: false
    )
  end

  defp environment!(project, overrides) do
    Ash.create!(
      Environment,
      Map.merge(
        %{
          project_id: project.id,
          name: unique("env"),
          target_stack: :elixir,
          template_name: "elixir-1.20",
          availability_mode: :on_demand,
          idle_timeout_seconds: 300
        },
        overrides
      ),
      action: :create,
      authorize?: false
    )
  end

  defp unique(prefix), do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  describe "the host's data layer wins (FR-009)" do
    test "both resources resolve to the host's ETS layer, not a Postgres-only template" do
      assert Ash.Resource.Info.data_layer(Project) == Ash.DataLayer.Ets
      assert Ash.Resource.Info.data_layer(Environment) == Ash.DataLayer.Ets
    end

    test "the identities carry pre_check_with, since ETS cannot enforce them itself" do
      assert %{pre_check_with: AshSandbox.HostApp.Sandboxes} =
               Ash.Resource.Info.identity(Project, :unique_name_per_owner)

      assert %{pre_check_with: AshSandbox.HostApp.Sandboxes} =
               Ash.Resource.Info.identity(Environment, :unique_name_per_project)
    end
  end

  describe "creating an environment through a non-Postgres host" do
    test "an environment is created in the host's project" do
      project = project!()
      environment = environment!(project, %{name: "preview"})

      assert environment.project_id == project.id
      assert environment.name == "preview"
      assert environment.availability_mode == :on_demand
      assert environment.idle_timeout_seconds == 300
    end

    test "the library's validations still apply -- an always_running idle timeout is refused" do
      project = project!()

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(
                 Environment,
                 %{
                   project_id: project.id,
                   name: unique("env"),
                   target_stack: :elixir,
                   template_name: "elixir-1.20",
                   availability_mode: :always_running,
                   idle_timeout_seconds: 300
                 },
                 action: :create,
                 authorize?: false
               )
    end
  end

  describe "the identities are enforced, not merely declared" do
    test "two environments in one project cannot share a name" do
      project = project!()
      environment!(project, %{name: "staging"})

      assert_raise Ash.Error.Invalid, fn ->
        environment!(project, %{name: "staging"})
      end
    end

    test "the same name in a different project is fine -- the scope is the project" do
      name = unique("env")
      first = environment!(project!(), %{name: name})
      second = environment!(project!(), %{name: name})

      assert first.name == second.name
      refute first.project_id == second.project_id
    end

    test "two projects of one owner cannot share a name" do
      name = unique("proj")
      project!("owner-b", name)

      assert_raise Ash.Error.Invalid, fn -> project!("owner-b", name) end
    end

    test "a different owner may reuse the name -- a global constraint would leak across owners" do
      name = unique("proj")

      assert project!("owner-c", name).name == project!("owner-d", name).name
    end
  end

  # ⚠️ These two live here, in the library, and not in the host, because the
  # host can no longer reach them. `Axonn.Sandbox.Changes.DeriveAvailability`
  # computes `availability_mode` and writes the matching timeout in the same
  # breath -- the platform default when it lands `:on_demand` with none given,
  # `nil` when it lands `:always_running` -- so neither refusal below has a
  # reachable caller once a host names an `availability_derivation:`. This
  # binding names none, so the un-derived template is live here and this is the
  # last place in the repository where these validations can be observed
  # failing. Without this block someone could delete either `validate` and the
  # whole suite would stay green, which is the definition of a check nobody has
  # watched fail.
  describe "⚠️ the timeout validations, where they are still reachable (003-FR-016)" do
    test "an on_demand environment with no idle timeout is refused, by that message" do
      project = project!()

      {:error, error} =
        Ash.create(
          Environment,
          %{
            project_id: project.id,
            name: unique("env"),
            target_stack: :elixir,
            template_name: "elixir-1.20",
            availability_mode: :on_demand,
            idle_timeout_seconds: nil
          },
          action: :create,
          authorize?: false
        )

      assert %Ash.Error.Invalid{} = error

      assert Exception.message(error) =~
               "an on_demand environment needs an idle timeout (003-FR-016)"
    end

    test "an always_running environment carrying an idle timeout is refused, by that message" do
      project = project!()

      {:error, error} =
        Ash.create(
          Environment,
          %{
            project_id: project.id,
            name: unique("env"),
            target_stack: :elixir,
            template_name: "elixir-1.20",
            availability_mode: :always_running,
            idle_timeout_seconds: 300
          },
          action: :create,
          authorize?: false
        )

      assert %Ash.Error.Invalid{} = error
      assert Exception.message(error) =~ "an always_running environment has no idle timeout"
    end
  end
end
