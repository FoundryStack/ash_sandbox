defmodule AshSandbox.ProjectTemplate do
  @moduledoc """
  A named grouping of environments belonging to one owner (003 T006).

      defmodule MyApp.Project do
        use AshSandbox.ProjectTemplate,
          data_layer: AshPostgres.DataLayer,
          domain: MyApp.Sandboxes,
          repo: MyApp.Repo,
          table: "projects"
      end

  Same template shape and the same reason as `AshSandbox.RegistryTemplate`: a
  library-declared resource has its data layer frozen into the beam at library
  compile time, so the host must own the declaration (`012` research R5).

  ## `owner_ref` replaces `tenant_id`

  A bare string the library stores and compares but never parses, resolves, or
  joins against (`012-FR-007`). **Axonn supplies its tenant id**, and declares
  the `belongs_to` to `002`'s `Tenant` on its own side — the library has no
  tenant concept and must compile without one.

  The requirement is unchanged by the substitution: `003-FR-002` requires one
  owner's resources be unreachable from another's, which turns on the values
  differing, not on what they mean.
  """

  @doc false
  defmacro __using__(opts) do
    data_layer = Macro.expand(Keyword.fetch!(opts, :data_layer), __CALLER__)
    domain = Keyword.fetch!(opts, :domain)
    table = Keyword.fetch!(opts, :table)
    repo = Keyword.get(opts, :repo)

    quote do
      use Ash.Resource, domain: unquote(domain), data_layer: unquote(data_layer)

      unquote(AshSandbox.Internal.DataLayerSection.build(data_layer, table, repo))

      attributes do
        uuid_v7_primary_key(:id)

        # Opaque (012-FR-007).
        attribute :owner_ref, :string do
          allow_nil?(false)
          public?(true)
        end

        attribute :name, :string do
          allow_nil?(false)
          public?(true)
        end

        create_timestamp(:inserted_at)
        update_timestamp(:updated_at)
      end

      identities do
        # Names are unique **within an owner**, not globally. A global
        # constraint would let one owner's choice of project name deny it to
        # every other owner -- an observable cross-owner effect, which is
        # precisely what FR-002 forbids.
        identity(:unique_name_per_owner, [:owner_ref, :name])
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          accept([:owner_ref, :name])
        end

        update :rename do
          accept([:name])
        end
      end
    end
  end
end
