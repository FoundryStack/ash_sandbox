# Choose a template

Six templates. You do not need all of them, and the order below is the order they become necessary.

| Template | Model this when | Requires |
|---|---|---|
| `AshSandbox.RegistryTemplate` | Always. It is the sandbox record — one row per sandbox, and the state machine | `data_layer`, `domain`, `table` |
| `AshSandbox.ProjectTemplate` | Sandboxes belong to something an owner names | `data_layer`, `domain`, `table` |
| `AshSandbox.EnvironmentTemplate` | One project needs more than one sandbox — `preview`, `staging`, `production` | the above plus `project_resource`, `registry_resource` |
| `AshSandbox.TemplateTemplate` | Sandboxes provision from pre-built images rather than from nothing | `data_layer`, `domain`, `table` |
| `AshSandbox.OperationRecordTemplate` | You need to answer "what happened to this sandbox, and why" after the fact | `data_layer`, `domain`, `table` |
| `AshSandbox.SandboxCredentialTemplate` | Each sandbox gets its own database role | the above plus `sandbox_resource` |

`repo:` is accepted by all six and used only by data layers that have one. On `AshPostgres.DataLayer`
it is required; on `Ash.DataLayer.Ets` pass nothing.

## The smallest useful set is one

A host that only wants sandbox records writes one module:

```elixir
defmodule MyApp.Sandbox do
  use AshSandbox.RegistryTemplate,
    data_layer: AshPostgres.DataLayer,
    domain: MyApp.Sandboxes,
    repo: MyApp.Repo,
    table: "sandboxes"
end
```

`environment_ref` is required even here, and it is what makes "one sandbox per environment" a
database constraint rather than an application check that races. **A host with no environment
concept passes the sandbox's own id.** Do not pass `nil` and do not make it nullable in your own
copy: every sandbox that omitted it would share the identity value `nil`, and the upsert would
match them all against each other — measured, and it produced one row for two provisions with
different owners.

## Templates that name your other modules

Two of the six take a module reference, and in both cases it is a reference the library cannot
guess.

**`EnvironmentTemplate` wants `registry_resource`** because `update` accepts `:network_allowlist`
and refuses the change while the environment has a live sandbox. Deciding liveness means reading
your registry. It is required rather than optional on purpose: an optional reference means the
guard is silently skipped for hosts that forgot it, which is a control that reports success and
changes nothing.

**`SandboxCredentialTemplate` wants `sandbox_resource`** for its `belongs_to`, and on AshPostgres it
declares `on_delete: :delete` at the database. A credential has no meaning without its sandbox, and
sequencing the deletion in application code instead fails in a way you will not see: destroying the
registry row hits the foreign key, the saga's compensation reports an error nobody reads, and the
credential survives as an orphan.

## Choosing a data layer

The templates are data-layer agnostic by construction (`012-FR-009`) and this is tested against
`Ash.DataLayer.Ets`, not asserted. Two things do change with the choice:

* **PostgreSQL enforces a unique identity with an index**, which *is* the guarantee. Other data
  layers cannot, so the templates attach `pre_check_with` for them — Ash then adds an
  `eager_validate_identities` hook to the `before_action` phase, and any `before_action` hook makes
  an update non-atomic. The templates handle that themselves
  (`AshSandbox.Internal.DataLayerSection.require_atomic/1`); you do not, and you should not copy the
  `require_atomic? false` into your own actions on PostgreSQL, where it would give up an atomicity
  you actually have.
* **`postgres do ... end` blocks are emitted only for `AshPostgres.DataLayer`.** A host on ETS or
  Mnesia is a legitimate consumer and must not be handed one.

## Taking the availability choice away from callers

By default `availability_mode` is caller input, and `idle_timeout_seconds` must agree with it: an
`on_demand` environment requires a timeout, an `always_running` one refuses to store one.

If your host derives availability from something of its own — a plan, an entitlement, a purpose —
pass a change module:

```elixir
use AshSandbox.EnvironmentTemplate,
  # ...
  availability_derivation: MyApp.AvailabilityFromPlan
```

Three things then happen: `:availability_mode` leaves the accept lists of `create` and `update`, the
module runs on both, and an `update :rederive_availability` appears that runs it and nothing else.

⚠️ The module must write `availability_mode` **and** `idle_timeout_seconds` together — the
validations reject a disagreeing pair — and must write them while the changeset is being built,
not in a `before_action` hook, because those validations run after the action's changes and before
any hook.

The library deliberately does not ship such a rule. What a purpose implies about availability
depends on the host's commercial arrangement with the owner, and a library that knows what `:free`
and `:paid` mean has stopped being a library.

## What no template will do for you

None of them resolves `target_stack` into a mechanism. That is the host's (`012-FR-001`): this
library cannot assume the host is an OTP application of a particular name, so it supplies no
configuration key. An unknown stack must be an error naming the stack — never a fallback to a
default, which would run tenant code under an isolation model nobody chose.
