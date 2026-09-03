defmodule AshSandbox.TemplateTemplate do
  @moduledoc """
  A pre-built, versioned application environment with dependencies installed
  (003 T010, FR-008).

      defmodule MyApp.SandboxTemplate do
        use AshSandbox.TemplateTemplate,
          data_layer: AshPostgres.DataLayer,
          domain: MyApp.Sandboxes,
          repo: MyApp.Repo,
          table: "sandbox_templates"
      end

  Read-only source for new sandboxes. Templates are **built by each stack's
  adapter** (`009-FR-053`–`FR-057`) with dependencies already compiled, so
  provisioning installs nothing (`003-FR-008`).

  What this resource contributes is knowing **what exists**, so provisioning can
  fail naming a missing template rather than starting an empty environment.
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

      # Readable by any permitted owner, writable only by platform admin
      # (data-model.md §Authorization, `FR-008`).
      #
      # Templates are shared infrastructure rather than tenant data: they carry
      # no `owner_ref`, so the owner filter the other resources use has nothing
      # to compare. Any actor may read; writes go through `authorize?: false`,
      # which is how platform-admin work is expressed here.
      #
      # "Any permitted owner" rather than "any active tenant" is deliberate --
      # activeness is a lifecycle concept the library does not have
      # (`012-FR-008`).
      policies do
        policy action_type(:read) do
          authorize_if(always())
        end

        policy always() do
          forbid_if(always())
        end
      end

      unquote(AshSandbox.Internal.DataLayerSection.build(data_layer, table, repo))

      attributes do
        uuid_v7_primary_key(:id)

        attribute :name, :string do
          allow_nil?(false)
          public?(true)
        end

        attribute :version, :string do
          allow_nil?(false)
          public?(true)
        end

        attribute :target_stack, :atom do
          allow_nil?(false)
          public?(true)
        end

        # The language runtime the template expects (`005-FR-022`).
        attribute :runtime_version, :string do
          allow_nil?(false)
          public?(true)
        end

        # A template can be withdrawn without being deleted -- environments
        # referencing it by name must still fail naming it, which a deleted row
        # could not do.
        attribute :available, :boolean do
          allow_nil?(false)
          default(true)
          public?(true)
        end

        create_timestamp(:inserted_at)
        update_timestamp(:updated_at)
      end

      identities do
        identity(:unique_name_version, [:name, :version])
      end

      actions do
        defaults([:read, :destroy])

        create :register do
          description("""
          Declares that a pre-built template exists, so provisioning can fail
          naming a missing one rather than starting an empty environment. It
          builds nothing — the image is produced by the stack's adapter — and
          the read policy is the only one that admits an ordinary actor, so
          registering goes through `authorize?: false`.
          """)

          accept([:name, :version, :target_stack, :runtime_version, :available])
        end

        update :withdraw do
          description("""
          Marks a template unavailable without deleting it. The row has to
          survive so that an environment still naming this template fails
          naming it; a deleted row could not say what was withdrawn.
          """)

          accept([])
          change(set_attribute(:available, false))
        end
      end
    end
  end
end
