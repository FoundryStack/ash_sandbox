defmodule AshSandbox.Internal.SetPurposeFromArgument do
  @moduledoc """
  Writes `purpose` from the `:purpose` argument, and only when one was given
  (`derive-availability-from-plan-and-purpose` 2.1).

  ## Why an argument and a change rather than an accepted attribute

  `update` must be able to tell *"leave the purpose alone"* from *"make it
  development"*. An accepted attribute cannot: the absent key and the key set
  to its default are the same thing to a caller building a map, and the one
  shape that distinguishes them — accepting `nil` — would make `nil` a value
  somebody could store into a column that is `allow_nil?: false`.

  A nullable argument says it exactly. `nil` means nothing was stated, and this
  change then writes nothing, so `create` falls through to the attribute's own
  `:development` default and `update` keeps whatever the row already carried.

  ## Why it runs while the changeset is built

  A host that derives `availability_mode` from `purpose` reads it in a change
  of its own declared immediately after this one, and that derivation has to
  land before the template's mode/timeout validations run. Both therefore write
  attributes directly rather than from a `before_action` hook — those run after
  every validation, which is far too late to be the input to one.
  """
  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    case Changeset.get_argument(changeset, :purpose) do
      nil -> changeset
      purpose -> Changeset.force_change_attribute(changeset, :purpose, purpose)
    end
  end
end
