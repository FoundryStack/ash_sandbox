defmodule AshSandbox.SandboxCredentialTemplate do
  @moduledoc """
  A generated, rotatable credential scoped to one sandbox's data store
  (003 T035, FR-018 – FR-021, research R3).

      defmodule MyApp.SandboxCredential do
        use AshSandbox.SandboxCredentialTemplate,
          data_layer: AshPostgres.DataLayer,
          domain: MyApp.Sandboxes,
          repo: MyApp.Repo,
          table: "sandbox_credentials",
          sandbox_resource: MyApp.SandboxRecord
      end

  ## Containment comes from the grant, not from concealment

  `FR-019` requires a credential issued to one sandbox be unusable from any
  other sandbox or from the host. That rules out the obvious implementation:
  the tenant's application must connect to its own database, so **the
  credential is necessarily readable by tenant code** — the spec says so
  outright (Story 3).

  So the containment cannot come from hiding it. It comes from the credential
  granting nothing anywhere else: one `LOGIN` role per sandbox, with privileges
  only on that sandbox's own logical database (`013-FR-007`, `013-FR-008`).

  A conformance test asserting that reading the credential *fails* would be
  testing the wrong guarantee, and would fail a correct implementation
  (003 T032).

  ## `sensitive? true` is the mechanism for FR-021, not a hint

  Ash redacts sensitive attributes from inspect output and from error messages
  — which is where credentials actually leak: a crashed changeset printed into
  a log, an `{:error, changeset}` inspected in a test failure, a struct dumped
  by an observer. Set on the attribute, it holds **everywhere the value
  travels**, including code paths written later by someone who has never read
  this requirement.

  That last property is why it is the mechanism rather than a convention. A
  convention protects the call sites its author remembered.

  ## Rotation replaces the secret, never the row

  `FR-020` requires rotation without rebuilding or destroying the sandbox. The
  role identity is stable and only the secret changes (`ALTER ROLE ...
  PASSWORD`), with `version` incremented in place — see research R4.

  Rotation does **not** have to be restart-free: the spec's own acceptance
  scenario says "takes effect without rebuilding or destroying" while its
  independent test says "works with the new one after a restart". Live
  replacement would require every generated application to re-read credentials
  at runtime, which is a stack assumption Principle VI forbids.
  """

  @doc false
  defmacro __using__(opts) do
    data_layer = Macro.expand(Keyword.fetch!(opts, :data_layer), __CALLER__)
    domain = Keyword.fetch!(opts, :domain)
    table = Keyword.fetch!(opts, :table)
    repo = Keyword.get(opts, :repo)
    sandbox_resource = Keyword.fetch!(opts, :sandbox_resource)

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: unquote(data_layer),
        authorizers: [Ash.Policy.Authorizer]

      # `FR-021`, data-model.md §Authorization: the credential is **never**
      # readable through an owner-facing action -- only by the provisioning path
      # that injects it, which runs `authorize?: false`.
      #
      # This is stricter than the owner filter the other resources use, and
      # deliberately so. "The owner may read its own credential" sounds
      # reasonable and is the wrong rule: it puts every sandbox secret one
      # actor-shaped request away from any code path that forwards a scope.
      policies do
        policy always() do
          forbid_if(always())
        end
      end

      unquote(AshSandbox.Internal.DataLayerSection.build(data_layer, table, repo))

      attributes do
        uuid_v7_primary_key(:id)

        # The PostgreSQL role. Unique because two sandboxes sharing a role
        # would share its grants, which is FR-019's failure in one line.
        attribute :role_name, :string do
          allow_nil?(false)
          public?(true)
        end

        # `AshSandbox.EncryptedSecret` and `sensitive? true` protect against
        # different readers and neither implies the other: the type encrypts
        # the stored bytes, `sensitive?` keeps the decrypted value out of
        # inspect and error output. A credential needs both.
        attribute :secret, AshSandbox.EncryptedSecret do
          allow_nil?(false)
          sensitive?(true)
          # Not `public?`: it must not be readable through an owner-facing
          # action. The provisioning path reads it with `authorize?: false`
          # when injecting it at sandbox start (data-model.md §Authorization).
          public?(false)
        end

        # Which logical database this credential is granted on (013-FR-007).
        # Recorded so a rotation or a revoke knows where to act without
        # re-deriving it.
        attribute(:data_store_ref, :string, public?: true)

        attribute(:rotated_at, :utc_datetime_usec, public?: true)

        attribute :version, :integer do
          allow_nil?(false)
          default(1)
          public?(true)
        end

        create_timestamp(:inserted_at)
        update_timestamp(:updated_at)
      end

      relationships do
        belongs_to :sandbox, unquote(sandbox_resource) do
          allow_nil?(false)
          public?(true)
          attribute_type(:string)
        end
      end

      unquote(AshSandbox.Internal.DataLayerSection.cascade_reference(data_layer, :sandbox))

      identities do
        identity(:unique_role_name, [:role_name])
      end

      actions do
        defaults([:read, :destroy])

        create :issue do
          description("""
          Issues the credential a sandbox uses to reach its data store. The
          secret is an encrypted, `sensitive?` value, which is what keeps it out
          of inspect output and error messages; rotation replaces it in place
          rather than issuing a second row.
          """)

          accept([:sandbox_id, :role_name, :secret, :data_store_ref])
        end

        update :rotate do
          description("Replaces the secret in place; the row and role survive (FR-020).")

          argument :secret, AshSandbox.EncryptedSecret do
            allow_nil?(false)
            sensitive?(true)
          end

          accept([])

          change(set_attribute(:secret, arg(:secret)))
          change(set_attribute(:rotated_at, &DateTime.utc_now/0))
          # `unquote(...)` around the whole expression, so the `version`
          # reference is emitted as a bare AST node rather than being caught by
          # this `quote`'s hygiene -- which renames it and leaves the host with
          # "undefined variable version" at *their* compile time, pointing at
          # their `use` line rather than at this file.
          change(
            atomic_update(
              :version,
              expr(unquote(Macro.var(:version, nil)) + 1)
            )
          )
        end
      end
    end
  end
end
