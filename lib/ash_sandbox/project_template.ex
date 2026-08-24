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
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: unquote(data_layer),
        authorizers: [Ash.Policy.Authorizer]

      # Load-bearing (003 T050): these records are not schema-isolated, so this
      # filter is the only boundary between two owners. Platform work reaches
      # them with `authorize?: false` rather than through a bypass.
      policies do
        policy always() do
          authorize_if(AshSandbox.Internal.OwnerCheck)
        end
      end

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
        # `pre_check_with` is derived from the data layer rather than fixed --
        # see `AshSandbox.Internal.DataLayerSection.pre_check_with/2` and the
        # measurements recorded above `RegistryTemplate`'s `:unique_environment`
        # identity. Hardcoding either branch loses a data layer: without it an
        # ETS host cannot compile the resource, with it a PostgreSQL host loses
        # atomic updates.
        identity :unique_name_per_owner,
                 [:owner_ref, :name],
                 unquote(AshSandbox.Internal.DataLayerSection.pre_check_with(data_layer, domain))
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
