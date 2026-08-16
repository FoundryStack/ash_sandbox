defmodule AshSandbox.OperationRecordTemplate do
  @moduledoc """
  The outcome of a lifecycle action (003 T011, FR-025, FR-027).

      defmodule MyApp.OperationRecord do
        use AshSandbox.OperationRecordTemplate,
          data_layer: AshPostgres.DataLayer,
          domain: MyApp.Sandboxes,
          repo: MyApp.Repo,
          table: "sandbox_operation_records"
      end

  ## Attribution is stored, not traversed

  `owner_ref`, `project_ref`, and `environment_ref` are **stored directly**
  rather than reached by walking sandbox → environment → project.

  That looks like denormalisation and is not. A failed provision must stay
  attributable *after the saga has rolled its environment row back* (003
  research R2) — and a failed provision is exactly when attribution is needed.
  Attribution that depends on the success path is attribution that vanishes at
  the moment it matters, and it fails silently, because the happy path it was
  tested on still works.

  For the same reason `sandbox_ref` is nullable: a provision that failed before
  the sandbox row existed still produced an operation worth recording.

  ## `failure_reason` is the same closed set as the registry

  `FR-027` requires the sandbox-specific causes stay distinguishable rather than
  collapsing into one generic error. A free-text field satisfies the type and
  fails the requirement — see `AshSandbox.RegistryTemplate`.

  ## No secret ever reaches here

  `FR-021`. `AshSandbox.SandboxCredentialTemplate` marks its secret
  `sensitive? true`, which is what keeps it out of inspect output and error
  messages; this resource simply has nowhere to put one.
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

        # The full attribution chain, stored rather than traversed -- see the
        # moduledoc. Opaque values throughout (012-FR-007).
        attribute :owner_ref, :string do
          allow_nil?(false)
          public?(true)
        end

        attribute(:project_ref, :string, public?: true)
        attribute(:environment_ref, :string, public?: true)

        # Nullable: a provision that failed before the sandbox existed still
        # produced an operation worth recording.
        attribute(:sandbox_ref, :string, public?: true)

        attribute :action, :atom do
          allow_nil?(false)
          public?(true)

          constraints(
            one_of: [
              :provision,
              :start,
              :stop,
              :destroy,
              :rotate_credential,
              :create_data_store,
              :destroy_data_store
            ]
          )
        end

        attribute :result, :atom do
          allow_nil?(false)
          public?(true)
          constraints(one_of: [:success, :failure])
        end

        attribute :failure_reason, :atom do
          public?(true)

          constraints(
            one_of: [
              :timeout,
              :resource_cap,
              :template_missing,
              :host_unreachable,
              :mechanism_error
            ]
          )
        end

        attribute(:failure_detail, :string, public?: true)

        attribute :duration_ms, :integer do
          allow_nil?(false)
          public?(true)
        end

        attribute :occurred_at, :utc_datetime_usec do
          allow_nil?(false)
          public?(true)
        end

        create_timestamp(:inserted_at)
      end

      validations do
        # A failure with no reason is the generic error FR-027 exists to
        # prevent. Enforced here rather than left to callers, because the
        # caller most likely to omit it is the one handling an unexpected
        # failure -- the case that most needs a cause.
        validate present(:failure_reason) do
          where(attribute_equals(:result, :failure))
          message("a failed operation must record a distinguishable cause (003-FR-027)")
        end
      end

      actions do
        defaults([:read])

        create :record do
          accept([
            :owner_ref,
            :project_ref,
            :environment_ref,
            :sandbox_ref,
            :action,
            :result,
            :failure_reason,
            :failure_detail,
            :duration_ms,
            :occurred_at
          ])

          # `set_new_attribute`, not `set_attribute` with a `where`.
          #
          # The `where: [is_nil(:occurred_at)]` form looks right and is not: Ash
          # evaluates `is_nil(:occurred_at)` as ordinary Elixir -- it is `false`
          # for an atom -- and then tries to use `false` as a validation module,
          # so every write fails with `function false.validate/3 is undefined`.
          # A caller-supplied `occurred_at` must win, because the caller knows
          # when the operation happened and this changeset only knows when it
          # was recorded.
          change(set_new_attribute(:occurred_at, &DateTime.utc_now/0))
        end
      end
    end
  end
end
