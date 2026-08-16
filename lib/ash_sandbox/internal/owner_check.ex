defmodule AshSandbox.Internal.OwnerCheck do
  @moduledoc """
  Filters records to those whose `owner_ref` equals the actor's (003 T050,
  `FR-002`, `012-FR-003`).

  ## The scope is compared, never interpreted

  The actor arrives from the host and the library knows nothing about its
  shape beyond one thing: it may carry an owner reference. `owner_ref/1` below
  is the *entire* extent of the library's knowledge, and it reads a field
  rather than deriving one — no splitting on `:`, no downcasing, no trimming.

  Two owner references match when they are equal. That is the whole contract
  (`012-FR-003`). A library that normalised them would collapse two distinct
  owners whose references differ only in case, which is a tenant isolation
  failure produced by being helpful.

  ## Unrecognised actors match nothing

  An actor with no owner reference — `nil`, a bare atom, a struct with
  different fields — yields no filter that any record satisfies, so the read
  returns empty. Failing open here would make the policy a no-op for exactly
  the callers that got the actor shape wrong, which is the population most
  likely to be wrong about other things too.
  """
  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts), do: "record's owner_ref matches the actor's"

  @impl true
  def filter(actor, _authorizer, _opts) do
    case owner_ref(actor) do
      nil ->
        # `false` rather than an empty filter: an empty filter matches
        # everything, which is the failure this clause exists to prevent.
        expr(false)

      owner_ref ->
        expr(owner_ref == ^owner_ref)
    end
  end

  # The library's complete knowledge of the actor's shape. A host whose actor
  # carries its owner elsewhere maps it before calling in -- that mapping is
  # the host's, per `012-FR-003`.
  defp owner_ref(%{owner_ref: owner_ref}) when is_binary(owner_ref), do: owner_ref
  defp owner_ref(_actor), do: nil
end
