defmodule AshSandbox.RegistryTemplate do
  @moduledoc """
  The sandbox registry resource, as a template the **host** owns (012 T025,
  FR-009).

      defmodule MyApp.SandboxRegistry do
        use AshSandbox.RegistryTemplate,
          data_layer: AshPostgres.DataLayer,
          domain: MyApp.Sandboxes,
          repo: MyApp.Repo,
          table: "sandboxes"
      end

  The host declares data layer, repo, table, and domain; this library owns the
  attributes, actions, and semantics.

  ## Why a template and not a resource module

  ⚠️ Research R5's spike **falsified** the obvious alternative — the library
  declaring the resource and the host attaching a data layer afterward.

  `Ash.Resource.Info.data_layer/1` delegates to
  `Extension.get_persisted(resource, :data_layer)`. The data layer is written
  into the resource module's beam **when the library compiles**. With no
  declaration it is `Ash.DataLayer.Simple` — the no-persistence default — and
  it stays that way permanently. The host can add the resource to its own
  domain, and the whole thing compiles cleanly and exits 0, and nothing can ever
  be stored.

  That is the same failure shape as a boundary violation: compiles, exits 0,
  fails later. The alternative is recorded here because it *looks* right and
  nothing in the build will tell a future contributor otherwise.

  ## `__using__/1`'s options are public interface

  Because the host writes this call site, its options are public API under
  `FR-014`, and changing them is a breaking change under `FR-015`.

  ## Required options

    * `:data_layer` — the host's data layer
    * `:domain` — the host's Ash domain
    * `:repo` — required by `AshPostgres.DataLayer`; ignored by data layers
      that do not use one
    * `:table` — the host's table name

  ## What this library does not declare

  No data layer, no repo, no domain, no table, **and no multitenancy strategy**.
  The last is deliberate: `FR-003` forbids requiring any particular
  multi-tenancy model, and a library that declared `strategy: :context` would
  force one on every host.
  """

  @doc """
  The states in which a sandbox is **live** — it exists as far as its mechanism
  is concerned, whether or not it is serving traffic yet.

  ⚠️ **Enumerated, never expressed as "not stopped"** (029 T018 ruling). `state`
  below is a closed set precisely so that a state added later has to be
  classified deliberately: a negation would silently sort a new state into
  *settled*, and the one caller of this list refuses a write while a sandbox is
  live. `Axonn.Sandbox.EnvironmentAllowlistUpdateTest`'s partition test fails if
  the two lists here stop covering the constraint exactly. (It lives in the host
  because `AshSandbox.EnvironmentTemplate` cannot be exercised on this library's
  own ETS fixtures — see that module.)

  `:stopping` is live. A sandbox being torn down still has whatever its
  mechanism installed at launch, and it can still reach the network until the
  teardown completes.
  """
  @spec live_states() :: [atom()]
  def live_states, do: [:provisioning, :provisioned, :starting, :running, :stopping]

  @doc """
  The states in which a sandbox is **settled** — nothing is running under the
  rules it was launched with.

  The complement of `live_states/0` over `state`'s closed set, written out
  rather than derived, so that both halves have to be edited when the set grows.
  """
  @spec settled_states() :: [atom()]
  def settled_states, do: [:stopped, :failed, :destroyed]

  # Emitted at macro-expansion time, not at runtime inside the quote: a DSL
  # section has to exist when the resource's own macros expand, so a runtime
  # `if` around `postgres do ... end` fails to compile rather than being skipped.
  #

  @doc false
  defmacro __using__(opts) do
    data_layer = Macro.expand(Keyword.fetch!(opts, :data_layer), __CALLER__)
    domain = Keyword.fetch!(opts, :domain)
    table = Keyword.fetch!(opts, :table)
    repo = Keyword.get(opts, :repo)

    # ⚠️ WAS `[AshSandbox.Resource | ...]`. The template injected a Spark
    # extension giving every host a `sandbox do ... end` block declaring
    # mechanism, run policy and limits. Nothing ever read it back: the only
    # callers of `AshSandbox.Resource.Info` were `AshSandbox.Plug` and the
    # extension's own test, and both are withdrawn (R-12). A host now passes
    # its own extensions or none.
    extensions = Keyword.get(opts, :extensions, [])

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: unquote(data_layer),
        extensions: unquote(extensions),
        authorizers: [Ash.Policy.Authorizer]

      # Load-bearing, not defensive (003 T050, data-model.md §Authorization).
      #
      # Wherever a host places these records they are not schema-isolated the
      # way `002`'s tenant data is, so this policy is the *only* thing between
      # two tenants. That is materially weaker than placement-based isolation
      # and the reason these rules get their own test rather than being taken
      # on trust.
      policies do
        # Platform work -- reconciliation, capacity queries, orphan sweeps --
        # runs with no actor and legitimately spans owners (research R5). It is
        # reached by `authorize?: false` at the call site rather than by a
        # bypass here, so an actor-carrying request can never take this path.
        policy always() do
          authorize_if(AshSandbox.Internal.OwnerCheck)
        end
      end

      unquote(AshSandbox.Internal.DataLayerSection.build(data_layer, table, repo))

      attributes do
        # A plain string id, not `uuid_primary_key`: `ExSandbox.Sandbox.id` is
        # opaque and host-generated (`003-FR-010`), so the library must not
        # impose a UUID on a host whose ids are something else.
        attribute :id, :string do
          allow_nil? false
          primary_key? true
          public? true
        end

        # Opaque. Stored and compared, never parsed (FR-007).
        attribute :owner_ref, :string do
          allow_nil? false
          public? true

          # `trim?: false` because `owner_ref` is **opaque** (`012-FR-003`).
          # Ash's `:string` trims by default, which is right for a name a human
          # typed and wrong for an identifier the host owns: it silently
          # rewrites the value, so a record stored under one reference is
          # looked up under another and two owners whose references differ only
          # in surrounding whitespace collapse into one.
          constraints trim?: false, allow_empty?: true
        end

        attribute :template_ref, :string, public?: true

        # `003-FR-010`'s enforcement point. The identity below turns "one
        # sandbox per environment" into a database constraint; an
        # application-level check races, because two transactions can both read
        # "no sandbox" before either writes (003 research R7).
        #
        # A string rather than a uuid for the same reason `id` is: the host
        # decides what an environment is identified by.
        #
        # **Required, and that is load-bearing.** With this nullable, every
        # sandbox that omitted it shared the identity value `nil`, and the
        # upsert below matched them all against each other -- so provisioning a
        # second sandbox silently returned the first. `nils_distinct?` does not
        # save this: the upsert resolves on the identity before that setting
        # applies. Measured, not assumed: two provisions with different owners
        # produced one row.
        #
        # A host with no environment concept passes the sandbox's own id.
        attribute :environment_ref, :string do
          allow_nil? false
          public? true
        end

        # Where the sandbox can be reached once running (`003-FR-022`). Null
        # until then, and re-read on every start -- the address may differ
        # between runs, and a caller caching the old one sends traffic nowhere
        # (contracts/mechanism.md §start/1).
        attribute :address, :string, public?: true

        # ⚠️ Adding a value here means classifying it in `live_states/0` or
        # `settled_states/0` above. Nothing infers the classification, and a
        # state left out of both fails the partition test named there rather
        # than being treated as safe-to-update by default.
        attribute :state, :atom do
          allow_nil? false
          default :provisioning
          public? true

          constraints one_of: [
                        :provisioning,
                        :provisioned,
                        :starting,
                        :running,
                        :stopping,
                        :stopped,
                        :failed,
                        :destroyed
                      ]
        end

        # A **closed set** (`003-FR-027`, T009), constrained on the resource
        # rather than by convention.
        #
        # The tempting shape is a free-text string, and it satisfies the type
        # while failing the requirement: `FR-027` requires these causes stay
        # distinguishable, and a string field lets a caller write "error" and
        # collapse all four into one. `010-FR-004` states the general rule.
        #
        # A mechanism with a more specific cause maps to one of these and puts
        # the detail in `failure_detail`.
        attribute :failure_reason, :atom do
          public? true

          constraints one_of: [
                        :timeout,
                        :resource_cap,
                        :template_missing,
                        :host_unreachable,
                        :mechanism_error
                      ]
        end

        # The host's or mechanism's own words, recorded verbatim and never
        # interpreted (`012-FR-008`). Separate from `failure_reason` precisely
        # so detail cannot erode the closed set above.
        attribute :failure_detail, :string, public?: true

        # Opaque mechanism handle.
        attribute :mechanism_ref, :string, public?: true

        # The port an application inside the sandbox listens on, or null for a
        # sandbox that runs no reachable application (`003-FR-022`,
        # `studio/FR-007`). What the *host* port ends up being is the
        # mechanism's to choose and is recorded in `address` once it starts;
        # this is the container's side of that mapping, and a sandbox that
        # names none is published nowhere at all.
        #
        # Set by the platform when the sandbox is opened, never by a request:
        # it is a fact about what the platform put inside the sandbox, which no
        # caller is in a position to know.
        attribute :service_port, :integer, public?: true

        # The host directory the sandbox's filesystem is opened over, or null
        # for a sandbox with no shared workspace. The agent writes here and the
        # application inside the sandbox reads the same bytes, which is what
        # makes an edit visible to a running server without a copy step.
        #
        # ⚠️ Absolute, and the platform's to derive -- never a path a request
        # supplies. A caller-supplied path is a caller-chosen mount of the
        # host's filesystem into a container, which is not a workspace feature
        # but an escape from every confinement above.
        attribute :workspace_path, :string, public?: true

        attribute :cpu_limit, :integer, public?: true
        attribute :memory_limit_mb, :integer, public?: true
        attribute :disk_quota_mb, :integer, public?: true

        # Which mechanism backs this sandbox. Recorded so reconciliation can ask
        # the right one; **not** for callers to branch on (Principle VI).
        attribute :mechanism, :atom, public?: true

        # What the host this sandbox was launched on could actually enforce
        # (`029-FR-040`), as `ExSandbox.Hardening.tier/0` measured it at
        # provision time.
        #
        # ⚠️ **Recorded, never derived** -- the same rule as
        # `data_store_placement` above, for a sharper reason. A tier computed
        # when the row is *read* describes the host doing the reading, so a
        # sandbox provisioned on a reduced host reads as fully enforced from
        # anywhere that is not reduced. `FR-040`'s whole point is that "a
        # reduced tier that is not recorded is indistinguishable from an
        # enforced one".
        #
        # ⚠️ Paired with `mechanism` above and useless without it. The tier
        # names what the *host* could enforce; the mechanism names who was
        # asked to do the enforcing. A second mechanism will eventually write
        # this field, and a tier with no mechanism beside it does not say whose
        # enforcement it describes.
        attribute :enforcement_tier, :string, public?: true

        # The sandbox's own logical database (`013-FR-007`) and which server
        # holds it (`013-FR-007c`).
        #
        # Placement is **recorded, never derived**. Deriving it from a fixed
        # location makes adding a second database server a migration over every
        # existing sandbox; storing it makes that a placement decision at
        # provisioning time. One column now instead of a data migration later.
        attribute :data_store_ref, :string, public?: true
        attribute :data_store_placement, :string, public?: true

        # ⚠️ `last_request_at` stood here, described as driving idle-stop
        # (`003-FR-016`). Nothing ever wrote it: the `touch` action that set it
        # had no caller in any host, so the *input* to an idle decision was
        # always `nil` and `005`'s idle-stop was never implementable against
        # it. `022`'s spec recorded this and it stayed. The column is removed
        # rather than left nullable, because a timestamp named
        # `last_request_at` reads as evidence that requests are being tracked.
        #
        # Reviving idle-stop means adding the write path first and this column
        # with it.

        # Set on every transition, so an operation's duration is derivable from
        # the record rather than only from the emitting call site.
        attribute :state_changed_at, :utc_datetime_usec, public?: true

        create_timestamp :inserted_at
        update_timestamp :updated_at
      end

      identities do
        # `003-FR-010`. This constraint *is* the idempotency guarantee -- see
        # `environment_ref` above. Declared here rather than left to the host
        # because a host that omitted it would silently lose FR-010 while every
        # test that provisions sequentially still passed.
        # `pre_check_with` is set only for data layers that cannot enforce an
        # identity themselves -- see `pre_check_with/2` below. Both branches
        # were measured, and neither is a safe default:
        #
        #   * **With** it on PostgreSQL, Ash adds an `eager_validate_identities`
        #     hook to the `before_action` phase of *every* action on this
        #     resource, including updates that never touch `environment_ref`.
        #     Any `before_action` hook makes an update non-atomic, so
        #     `mark_provisioned`, `mark_running`, and the rest all failed with
        #     `MustBeAtomic` -- the whole state machine was unusable.
        #
        #   * **Without** it on ETS, Ash's `RequirePreCheckWith` verifier
        #     refuses to compile the resource at all, because ETS cannot enforce
        #     a unique constraint and would silently permit duplicates.
        #
        # Both are `FR-009` in practice: the host chooses the data layer, so the
        # library has to derive this from it rather than pick one.
        identity :unique_environment,
                 [:environment_ref],
                 unquote(AshSandbox.Internal.DataLayerSection.pre_check_with(data_layer, domain))
      end

      actions do
        defaults [:read, :destroy]

        create :provision do
          accept [
            :id,
            :owner_ref,
            :template_ref,
            :environment_ref,
            :service_port,
            :workspace_path,
            :cpu_limit,
            :memory_limit_mb,
            :disk_quota_mb,
            :mechanism,
            :enforcement_tier,
            :data_store_ref,
            :data_store_placement
          ]

          # `003-FR-010` and research R7: a concurrent second provision returns
          # the existing row rather than raising. The database arbitrates, not
          # application code -- a check-then-act races even inside a
          # transaction, because both transactions can read "no sandbox" before
          # either writes.
          upsert? true
          upsert_identity :unique_environment

          # Deliberately empty: the loser of the race gets the winner's row
          # back untouched. Overwriting here would let a late arrival stamp its
          # own template or limits over a sandbox already running with others.
          upsert_fields []

          change set_attribute(:state, :provisioning)

          # `&DateTime.utc_now/0` here and `expr(now())` on every `update`
          # below. Not a stylistic inconsistency: `expr(now())` keeps an update
          # atomic -- without it the function value adds a `before_action` hook
          # and Ash refuses the action with `MustBeAtomic` -- but on a *create*
          # there is no atomic path to preserve and the expression reaches the
          # cast as an unevaluated `now()`, which fails with "could not cast
          # input to datetime".
          change set_attribute(:state_changed_at, &DateTime.utc_now/0)
        end

        update :mark_provisioned do
          # `data_store_ref` and `data_store_placement` are accepted here, not
          # only at `:provision`, because they are not known when the row is
          # created: the row is created *first* so that a crash mid-saga leaves
          # something reconciliation can find, and the database it names does not
          # exist yet at that point. Placement especially is a fact about where
          # the sandbox actually landed (`013-FR-007c`) -- recorded when it is
          # known rather than guessed when the row is opened.
          accept [:mechanism_ref, :address, :data_store_ref, :data_store_placement]
          change set_attribute(:state, :provisioned)
          change atomic_update(:state_changed_at, expr(now()))
        end

        # `starting` is a distinct state, not a flag (`003-FR-024`, T012).
        # `006-domain-routing` chooses between starting a sandbox on demand and
        # reporting a fault, and it cannot make that choice if "start in
        # progress" and "not running" are the same value.
        update :mark_starting do
          accept []
          change set_attribute(:state, :starting)
          change atomic_update(:state_changed_at, expr(now()))
        end

        # `address` is required here, not merely accepted: `003-FR-022` says a
        # running sandbox has a recorded address, and a `running` row with a
        # null address is a sandbox nothing can reach while everything reports
        # it healthy.
        update :mark_running do
          accept [:mechanism_ref, :address]

          validate present(:address) do
            message "a sandbox cannot be running without a recorded address (003-FR-022)"
          end

          change set_attribute(:state, :running)
          change set_attribute(:failure_reason, nil)
          change set_attribute(:failure_detail, nil)
          change atomic_update(:state_changed_at, expr(now()))
        end

        update :mark_stopping do
          accept []
          change set_attribute(:state, :stopping)
          change atomic_update(:state_changed_at, expr(now()))
        end

        # The address is cleared on stop. `start/1` returns a possibly-different
        # one (contracts/mechanism.md), so keeping the old value would leave a
        # stale address that looks current.
        update :mark_stopped do
          accept []
          change set_attribute(:state, :stopped)
          change set_attribute(:address, nil)
          change atomic_update(:state_changed_at, expr(now()))
        end

        update :mark_failed do
          # An atom from the closed set, so a caller cannot invent a reason.
          argument :reason, :atom, allow_nil?: false
          argument :detail, :string

          accept []
          change set_attribute(:state, :failed)
          change set_attribute(:failure_reason, arg(:reason))
          change set_attribute(:failure_detail, arg(:detail))
          change atomic_update(:state_changed_at, expr(now()))
        end

        update :mark_destroyed do
          accept []
          change set_attribute(:state, :destroyed)
          change set_attribute(:address, nil)
          change atomic_update(:state_changed_at, expr(now()))
        end
      end

      @doc """
      Builds the plain `ExSandbox.Sandbox` struct a mechanism receives.

      The mechanism never sees this Ash resource — `012` research R3. Fields
      that exist for the host's benefit stay here and do not cross.

      ## What is deliberately withheld

      `environment_ref`, `data_store_ref`, `data_store_placement`, `address`,
      `state`, `state_changed_at`, and the timestamps.

      Each is registry bookkeeping. A mechanism that needed any of them would be
      reaching into host concepts — and `state` above all, because a mechanism
      reports **actual** state through `status/1` rather than reading recorded
      state. That asymmetry is what makes reconciliation possible: if the
      mechanism read the record, the two could never disagree, and `FR-015`
      would have nothing to detect.
      """
      @spec to_sandbox(struct(), term()) :: ExSandbox.Sandbox.t()
      def to_sandbox(record, context \\ nil) do
        %ExSandbox.Sandbox{
          id: record.id,
          owner_ref: record.owner_ref,
          template_ref: record.template_ref,
          cpu_limit: record.cpu_limit,
          memory_limit_mb: record.memory_limit_mb,
          disk_quota_mb: record.disk_quota_mb,
          mechanism_ref: record.mechanism_ref,
          service_port: record.service_port,
          workspace_path: record.workspace_path,
          context: context
        }
      end
    end
  end
end
