defmodule AshSandbox.EnvironmentTemplate do
  @moduledoc """
  A named deployment target within a project (003 T007).

      defmodule MyApp.Environment do
        use AshSandbox.EnvironmentTemplate,
          data_layer: AshPostgres.DataLayer,
          domain: MyApp.Sandboxes,
          repo: MyApp.Repo,
          table: "environments",
          project_resource: MyApp.Project,
          registry_resource: MyApp.SandboxRegistry
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

  ## `registry_resource` is required, and it is what makes the allowlist writable

  `update` accepts `:network_allowlist` and **refuses while the environment has
  a live sandbox** (029 T018 ruling) — see
  `AshSandbox.Internal.RefuseAllowlistChangeWhileLive` for why refusing is the
  honest shape. Deciding liveness means reading the host's registry, and the
  host names its own binding here rather than this library naming a module it
  cannot know (`012-FR-009`).

  ⚠️ **Required rather than optional, on purpose.** An optional reference has
  two shapes, and both are worse. Without it the guard is skipped — a control
  that reports success and changes nothing, the exact defect this exists to
  prevent — or the field silently stays unwritable and an operator meets "no
  such input" with nothing telling them why. A missing option is instead a
  compile error naming what to pass. (`012-FR-015` makes this a breaking change
  to a public interface; that requirement is deferred until a version is
  published, and there is no published version.)

  ## ⚠️ This template's tests live in the host, and not by preference

  MEASURED 2026-08-23: `identity(:unique_name_per_project, ...)` below carries no
  `pre_check_with`, so a host on ETS or Mnesia cannot compile this resource at
  all — `Ash.DataLayer.Verifiers.RequirePreCheckWith` refuses it with *"the data
  layer does not support native checking of identities"*. That makes this
  template AshPostgres-only in practice, which `012-FR-009` says it should not
  be, and it is why `ash_sandbox`'s own ETS `HostApp` fixtures bind a registry
  and no environment. `AshSandbox.RegistryTemplate` solves the same problem with
  `AshSandbox.Internal.DataLayerSection.pre_check_with/2`; the fix here is the
  same one line and is deliberately **not** folded into `029 T018` — it changes
  which hosts can compile, which is a different question from this write path.
  """

  @doc false
  defmacro __using__(opts) do
    data_layer = Macro.expand(Keyword.fetch!(opts, :data_layer), __CALLER__)
    domain = Keyword.fetch!(opts, :domain)
    table = Keyword.fetch!(opts, :table)
    repo = Keyword.get(opts, :repo)
    project_resource = Keyword.fetch!(opts, :project_resource)
    registry_resource = Keyword.fetch!(opts, :registry_resource)

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
        # Same derivation as `ProjectTemplate`'s identity, for the same reason
        # (`012-FR-009`): the host picks the data layer, so the library reads
        # `pre_check_with` off it instead of choosing for the host.
        identity :unique_name_per_project,
                 [:project_id, :name],
                 unquote(AshSandbox.Internal.DataLayerSection.pre_check_with(data_layer, domain))
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
          # ⚠️ `:network_allowlist` was declared above, made public and made
          # writable, and then accepted by no action -- so the only way to set
          # it was to build the environment map by hand, which is what every
          # test did and no operator can. `029-FR-011` names that shape
          # exactly: *a control that cannot be configured is not a control*.
          # Every map-built provision test passed over the gap.
          accept([
            :project_id,
            :name,
            :availability_mode,
            :target_stack,
            :template_name,
            :idle_timeout_seconds,
            :network_allowlist
          ])
        end

        # ⚠️ **`:network_allowlist` is accepted here, and refused while a
        # sandbox for this environment is live** (029 T018 ruling, resolving the
        # question this comment used to hold open). A sandbox is policed by
        # rules its mechanism installs at launch from the allowlist as it read
        # *then*; nothing re-reads it afterwards. Accepting the field unguarded
        # would let an operator narrow an allowlist and see the change persisted
        # while every running sandbox kept the wider rules -- a control that
        # reports success and changes nothing. Widening is the mirror: recorded,
        # and unreachable until the sandbox is replaced.
        #
        # Re-policing the running sandbox instead of refusing is the better
        # product answer and was not chosen: rewriting a live ruleset is its own
        # correctness problem, and `029` has not yet shown that the rules it
        # installs at launch hold at all -- the observation halves of its
        # enforcement tasks need a Linux network namespace and have never run.
        # `AshSandbox.Internal.RefuseAllowlistChangeWhileLive` carries the rest.
        update :update do
          # ⚠️ Needed, and only for the validation below. Deciding whether this
          # environment has a live sandbox is a read of another resource, which
          # no expression over this row can express -- so the validation has no
          # `atomic/3` and Ash would otherwise refuse the action with
          # `MustBeAtomic`. Scoped to this action rather than the `validations`
          # block so `:read` and `:destroy` keep their own paths untouched.
          #
          # ⚠️ Left unfixed, deliberately: this is a check-then-act, so a launch
          # that commits between the read and the write still leaves a narrowed
          # allowlist beside a sandbox running the wider rules. Closing it needs
          # the launch path to take the environment row under lock, which is
          # `029`'s enforcement work rather than this write path's.
          require_atomic?(false)

          accept([
            :availability_mode,
            :idle_timeout_seconds,
            :template_name,
            :network_allowlist
          ])

          validate(
            {AshSandbox.Internal.RefuseAllowlistChangeWhileLive,
             registry_resource: unquote(registry_resource)}
          )
        end
      end
    end
  end
end
