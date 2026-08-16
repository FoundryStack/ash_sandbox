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
end
