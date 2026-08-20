defmodule AshSandbox.EnvironmentTemplate do
  @moduledoc """
  A named deployment target within a project (003 T007).

      defmodule MyApp.Environment do
        use AshSandbox.EnvironmentTemplate,
          data_layer: AshPostgres.DataLayer,
          domain: MyApp.Sandboxes,
          repo: MyApp.Repo,
          table: "environments",
          project_resource: MyApp.Project
      end

  `preview`, `staging`, `production` — backed by exactly one sandbox.

  ## `target_stack` selects the mechanism

  It lives here rather than on the sandbox because the mechanism is a property
  of **what is being run**, not of the running instance, and it must be known
  *before* a sandbox exists in order to create one (003 research R1).

  Resolution is the host's (`012-FR-001`): `ex_sandbox` cannot assume the host
  is an OTP application named `:axonn`, so it supplies no configuration key.
  An unknown stack is an error naming the stack — never a fallback to a
  default, which would run tenant code under an isolation model nobody chose.

  ## `template_name` is recorded even when the template is absent

  So provisioning fails naming the missing template rather than starting an
  empty environment (`003-FR-008`, spec edge case). Validating its existence at
  creation time would be worse, not better: templates are built out of band and
  may be registered after an environment references one.
  """

  @doc false
  defmacro __using__(opts) do
    data_layer = Macro.expand(Keyword.fetch!(opts, :data_layer), __CALLER__)
    domain = Keyword.fetch!(opts, :domain)
    table = Keyword.fetch!(opts, :table)
    repo = Keyword.get(opts, :repo)
    project_resource = Keyword.fetch!(opts, :project_resource)

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

        # Denormalized from the owning `Project` at create time by
        # `AshSandbox.Internal.CopyOwnerRefFromProject` (018 Phase 1 T001-T003).
        # Opaque, same as `AshSandbox.ProjectTemplate`'s own `owner_ref` --
        # required so `AshSandbox.Internal.OwnerCheck`'s policy filter (which
        # every `*Template` in this library shares) has a column to compare
        # against without joining through `project` on every read.
        attribute :owner_ref, :string do
          allow_nil?(false)
          public?(true)
        end

        attribute :name, :string do
          allow_nil?(false)
          public?(true)
        end

        # `003-FR-016`. `on_demand` sandboxes are started on first request and
        # idle-stopped; `always_running` ones are kept up across host restarts.
        attribute :availability_mode, :atom do
          allow_nil?(false)
          default(:on_demand)
          public?(true)
          constraints(one_of: [:on_demand, :always_running])
        end

        attribute :target_stack, :atom do
          allow_nil?(false)
          public?(true)
        end

        attribute :template_name, :string do
          allow_nil?(false)
          public?(true)
        end

        # Only meaningful when `on_demand` -- see the validation below.
        attribute(:idle_timeout_seconds, :integer, public?: true)

        # `005-FR-011a`, `013-FR-014b`. The destinations a sandbox in this
        # environment may reach, as `"host:port"` or `"host:*"` strings.
        #
        # ⚠️ **`nil` and `[]` mean the same thing here -- reach nothing -- and
        # that is deliberate.** The alternative reading, "unset means
        # unrestricted", would make an environment created before this
        # attribute existed silently unconfined, which is the migration that
        # grants access nobody granted. Default-deny has to survive its own
        # rollout.
        #
        # Parsed by `ExSandbox.Egress.Allowlist.parse/1` at provision time
        # rather than validated here: the parser is what the enforcement path
        # actually uses, and a second validation written against the same
        # strings would be a second opinion that can drift from it.
        attribute :network_allowlist, {:array, :string} do
          allow_nil?(true)
          public?(true)
        end

        create_timestamp(:inserted_at)
        update_timestamp(:updated_at)
      end

      relationships do
        belongs_to :project, unquote(project_resource) do
          allow_nil?(false)
          public?(true)
        end
      end

      identities do
        identity(:unique_name_per_project, [:project_id, :name])
      end

      validations do
        # `003-FR-016`. Rejected rather than ignored when `always_running`: a
        # recorded idle timeout that never applies is a value someone will
        # later read and act on.
        validate absent(:idle_timeout_seconds) do
          where(attribute_equals(:availability_mode, :always_running))
          message("an always_running environment has no idle timeout")
        end

        validate present(:idle_timeout_seconds) do
          where(attribute_equals(:availability_mode, :on_demand))
          message("an on_demand environment needs an idle timeout (003-FR-016)")
        end
      end

      changes do
        change {AshSandbox.Internal.CopyOwnerRefFromProject, []}, on: [:create]
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          accept([
            :project_id,
            :name,
            :availability_mode,
            :target_stack,
            :template_name,
            :idle_timeout_seconds
          ])
        end

        update :update do
          accept([:availability_mode, :idle_timeout_seconds, :template_name])
        end
      end
    end
  end
end
