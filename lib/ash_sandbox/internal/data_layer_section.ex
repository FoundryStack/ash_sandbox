defmodule AshSandbox.Internal.DataLayerSection do
  @moduledoc false

  # Private (`012-FR-014`). Every `*Template` in this library needs the same
  # host-declared data layer block, and the block cannot be built at runtime:
  # a DSL section has to exist when the resource's own macros expand, so a
  # runtime `if` around `postgres do ... end` fails to compile rather than
  # being skipped.
  #
  # Data-layer-specific on purpose. A host on ETS or Mnesia is a legitimate
  # consumer (`012-FR-009`) and must not be handed a `postgres` block.

  @doc false
  def build(AshPostgres.DataLayer, table, repo) do
    quote do
      postgres do
        table(unquote(table))
        repo(unquote(repo))
      end
    end
  end

  def build(_other, _table, _repo), do: nil

  @doc false
  # A `references` block declaring `on_delete: :delete`.
  #
  # Needed because a credential has no meaning without its sandbox, and because
  # without it the saga's rollback becomes order-dependent in a way that fails
  # silently: destroying the registry row hits
  # `sandbox_credentials_sandbox_id_fkey`, the `undo` reports an error, and the
  # row survives as an orphan. Measured in `003` T023 -- the compensation ran,
  # said nothing useful, and left the row behind.
  #
  # Declared at the database rather than sequenced in application code, so it
  # holds for every deletion path including the ones written later.
  def cascade_reference(AshPostgres.DataLayer, relationship) do
    quote do
      postgres do
        references do
          reference(unquote(relationship), on_delete: :delete)
        end
      end
    end
  end

  def cascade_reference(_other, _relationship), do: nil

  @doc false
  # Identity options, empty or carrying `pre_check_with`.
  #
  # PostgreSQL enforces a unique identity with an index, which per `003`
  # research R7 *is* the FR-010 guarantee -- an application-level check races
  # regardless, since two transactions can both read "no sandbox" before either
  # writes. Adding a pre-check there buys nothing and costs atomicity on every
  # update of the resource.
  #
  # ETS and Mnesia cannot enforce it, so Ash's `RequirePreCheckWith` verifier
  # refuses to compile the resource without one.
  def pre_check_with(AshPostgres.DataLayer, _domain), do: []
  def pre_check_with(_other, domain), do: [pre_check_with: domain]

  @doc false
  # `require_atomic?(false)`, or nothing -- the `pre_check_with/2` note above
  # read in the other direction, and the reason it is a function rather than a
  # line written into each action.
  #
  # An identity carrying `pre_check_with` makes Ash add an
  # `eager_validate_identities` hook to the `before_action` phase of every
  # action on the resource, and ANY `before_action` hook makes an update
  # non-atomic. MEASURED 2026-09-10, on the test host application this library
  # ships: every `mark_*` transition on the registry and `:rename` on a project
  # raised `MustBeAtomic` on `Ash.DataLayer.Ets` while passing on PostgreSQL --
  # so templates whose whole claim is data-layer independence (`012-FR-009`)
  # worked on one data layer. Nothing caught it because no test in this library
  # ran an update against the ETS host.
  #
  # ⚠️ Conditional rather than unconditional, unlike the three call sites that
  # predate this helper. Those each argue why their own action loses nothing by
  # being non-atomic -- last-observation-wins, or a hook they already have. A
  # state transition is not in that class: on PostgreSQL these actions really
  # are atomic, `expr(now())` is what keeps them so, and turning that off for
  # every consumer to make ETS compile would pay for one data layer out of the
  # other's guarantee.
  def require_atomic(AshPostgres.DataLayer), do: nil

  def require_atomic(_other) do
    quote do
      require_atomic?(false)
    end
  end
end
