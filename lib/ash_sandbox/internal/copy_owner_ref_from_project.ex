defmodule AshSandbox.Internal.CopyOwnerRefFromProject do
  @moduledoc """
  Copies the owning `Project`'s `owner_ref` onto a new `Environment` at create
  time (018 Phase 1 T002, research R1).

  `AshSandbox.Internal.OwnerCheck` -- the policy filter every `*Template` in
  this library shares -- reads `actor.owner_ref` and compares it against the
  **record's own** `owner_ref` column. `Environment` has no independent notion
  of an owner; it belongs to a `Project`, which does. Denormalizing the value
  here, once, at create time is the same trade `Axonn.Agents.Thread.tenant_id`
  already makes and justifies in its own moduledoc: stored so policy checks
  can scope a read without joining through the parent on every query.

  ## Why `on: [:create]` only

  A `Project`'s `owner_ref` does not change after creation (`AshSandbox.ProjectTemplate`
  exposes no action that writes it), and an `Environment` cannot be
  re-parented to a different `Project` (`update :update` does not accept
  `project_id`). With both of those closed, there is no write path that could
  leave the copy stale, so there is nothing for an `:update` variant of this
  change to do.

  ## Why a lookup, not a load

  This runs in a `before_action` hook, before the `Environment` row exists, so
  there is no relationship to load yet -- the owning `Project` is fetched by
  the `project_id` the changeset already carries. The lookup runs with
  `authorize?: false`: this is denormalization of a value the caller already
  supplied (`project_id`), not an authorization decision, and policy
  enforcement for the `Environment` create itself is unaffected -- it still
  runs through `Environment`'s own policies.
  """
  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, &copy_owner_ref/1)
  end

  defp copy_owner_ref(changeset) do
    project_id = Changeset.get_attribute(changeset, :project_id)
    project_resource = project_resource(changeset.resource)

    case project_id && Ash.get(project_resource, project_id, authorize?: false) do
      {:ok, project} ->
        Changeset.force_change_attribute(changeset, :owner_ref, project.owner_ref)

      _ ->
        Changeset.add_error(changeset,
          field: :project_id,
          message: "must reference an existing project"
        )
    end
  end

  # Read off the resource's own `belongs_to :project` relationship rather than
  # hardcoding a module: the host names its own `Project` binding
  # (`012-FR-009`), and this library must compile without knowing it.
  defp project_resource(resource) do
    resource
    |> Ash.Resource.Info.relationship(:project)
    |> Map.fetch!(:destination)
  end
end
