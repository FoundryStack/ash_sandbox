# Getting started

By the end of this page you will have a project, an environment and a sandbox record stored, moved
through its lifecycle, and failed — in one script, with no database and no container.

That is on purpose. `ash_sandbox` models the **lifecycle**; `ex_sandbox` runs the **sandbox**. This
page is only the first half, and doing it against `Ash.DataLayer.Ets` keeps the setup to nothing.
[Choose a template](how-to/choose-a-template.md) covers moving to AshPostgres, which is the same
five modules with three more options each.

## 1. A file to run

Save this as `sandbox_tour.exs`. Everything below appends to it.

```elixir
Mix.install([
  {:ash_sandbox, github: "FoundryStack/ash_sandbox", tag: "v0.1.0"},
  {:picosat_elixir, "~> 0.2"}
])
```

`picosat_elixir` is a SAT solver, and it is not optional. Every template emits
`Ash.Policy.Authorizer` policies, and Ash needs a solver to evaluate one. Without it this compiles
and then raises `Picosat.solve/1 is undefined` on your first authorized read.

## 2. Your domain, your resources

The library ships **no resource modules**. You write them, and they are one `use` each:

```elixir
defmodule Tour.Sandboxes do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Tour.Project
    resource Tour.Environment
    resource Tour.Sandbox
  end
end

defmodule Tour.Project do
  use AshSandbox.ProjectTemplate,
    data_layer: Ash.DataLayer.Ets,
    domain: Tour.Sandboxes,
    table: "projects"
end

defmodule Tour.Sandbox do
  use AshSandbox.RegistryTemplate,
    data_layer: Ash.DataLayer.Ets,
    domain: Tour.Sandboxes,
    table: "sandboxes"
end

defmodule Tour.Environment do
  use AshSandbox.EnvironmentTemplate,
    data_layer: Ash.DataLayer.Ets,
    domain: Tour.Sandboxes,
    table: "environments",
    project_resource: Tour.Project,
    registry_resource: Tour.Sandbox
end
```

Three things are worth noticing before moving on.

**You declared the data layer, not the library.** That is the single decision this library's shape
turns on, and it is not stylistic — a library-declared resource has its data layer frozen into the
beam when the *library* compiles, so a host attaching one afterward gets a resource that compiles
cleanly, exits 0, and can never store anything. [Why the host owns the
module](explanation/why-the-host-owns-the-module.md) has the measurement.

**There is no `repo:` here.** It is accepted and ignored by data layers that do not use one. On
AshPostgres it is required.

**`Tour.Environment` names your other two modules.** The library cannot know them. `registry_resource`
is what lets an environment ask whether it has a live sandbox before allowing its network allowlist
to change.

## 3. A project and an environment

```elixir
{:ok, project} =
  Tour.Project
  |> Ash.Changeset.for_create(:create, %{owner_ref: "acct_42", name: "checkout"})
  |> Ash.create(authorize?: false)

{:ok, environment} =
  Tour.Environment
  |> Ash.Changeset.for_create(:create, %{
    project_id: project.id,
    name: "preview",
    target_stack: :elixir,
    template_name: "elixir-1.18",
    purpose: :development,
    idle_timeout_seconds: 900,
    network_allowlist: ["api.stripe.com:443"]
  })
  |> Ash.create(authorize?: false)

environment.owner_ref
# => "acct_42"
```

`authorize?: false` is how platform work is expressed here — reconciliation, capacity queries,
orphan sweeps. It legitimately spans owners, and it is reached at the call site rather than through
a policy bypass, so a request that *does* carry an actor can never take this path. Pass `actor:`
instead and every read is filtered to that actor's `owner_ref`.

Five details that will save you an afternoon:

* **`owner_ref` is opaque.** The library stores it, compares it, and never parses, resolves or
  joins against it. `"acct_42"` here is a string with no meaning to this library at all. Yours can
  be a UUID, a tenant id, or anything else.
* **You did not set `owner_ref` on the environment** and it has one. It is copied from the project,
  because an environment that could disagree with its project about who owns it is a data model
  with two answers.
* **`purpose` is an argument, not an attribute** — so "no purpose was stated" stays distinguishable
  from "development was stated". It defaults to `:development`, which is the safe half: a host
  deriving availability from it is then wrong in the direction that costs a cold start rather than
  the direction that keeps paying for an idle production sandbox.
* **`idle_timeout_seconds` is required here**, because the default availability mode is
  `:on_demand` and an on-demand environment nobody idle-stops is an always-running one that nobody
  said was always-running. Pass `availability_mode: :always_running` instead and the timeout is
  *refused* rather than ignored — a recorded idle timeout that never applies is a value someone
  reads later and acts on.
* **An empty or absent `network_allowlist` means reach nothing**, not reach everything. Default-deny
  has to survive its own rollout.

## 4. Provision a sandbox

```elixir
{:ok, sandbox} =
  Tour.Sandbox
  |> Ash.Changeset.for_create(:provision, %{
    id: "sbx_01",
    owner_ref: project.owner_ref,
    environment_ref: environment.id,
    template_ref: "elixir-1.18",
    mechanism: :docker,
    cpu_limit: 2,
    memory_limit_mb: 2048
  })
  |> Ash.create(authorize?: false)

sandbox.state
# => :provisioning
```

The row exists **before the thing it records does**. That is the point of `:provision`: a crash
mid-provision leaves something reconciliation can find, rather than an unreferenced container and
no evidence.

`id` is a plain string you chose, not a generated UUID — the host owns what a sandbox is identified
by. `environment_ref` is required, and it is what makes "one sandbox per environment" a database
constraint rather than a check that races. A host with no environment concept passes the sandbox's
own id.

**The limits you just wrote are requests.** `cpu_limit: 2` records what you asked for. Nothing
inside the BEAM enforces it; the operating system is the boundary, and enforcing it is
`ex_sandbox`'s job. See [Refusal is the design](https://hexdocs.pm/ex_sandbox/readme.html) for what
happens when the host cannot.

## 5. Walk the lifecycle

Every transition is its own named action, and each records `state_changed_at` atomically:

```elixir
{:ok, sandbox} =
  sandbox
  |> Ash.Changeset.for_update(:mark_provisioned, %{
    mechanism_ref: "docker://9f2c…",
    address: "127.0.0.1:8123"
  })
  |> Ash.update(authorize?: false)

{:ok, sandbox} =
  sandbox |> Ash.Changeset.for_update(:mark_starting, %{}) |> Ash.update(authorize?: false)

{:ok, sandbox} =
  sandbox
  |> Ash.Changeset.for_update(:mark_running, %{address: "127.0.0.1:8123"})
  |> Ash.update(authorize?: false)

sandbox.state
# => :running
```

`:starting` is a distinct state rather than a flag on `:stopped`. A caller deciding between starting
a sandbox on demand and reporting a fault cannot make that call if "start in progress" and "not
running" are the same value.

`address` is *required* by `:mark_running`, not merely accepted. A `running` row with no address is
a sandbox nothing can reach while every dashboard reports it healthy.

Try it on a sandbox that never got one:

```elixir
{:ok, addressless} =
  Tour.Sandbox
  |> Ash.Changeset.for_create(:provision, %{
    id: "sbx_02",
    owner_ref: project.owner_ref,
    environment_ref: "some-other-environment"
  })
  |> Ash.create(authorize?: false)

addressless
|> Ash.Changeset.for_update(:mark_running, %{})
|> Ash.update(authorize?: false)
# => {:error, ...} "a sandbox cannot be running without a recorded address (003-FR-022)"
```

⚠️ The validation reads the **record**, not the changeset, so running `:mark_running` with no
arguments on `sandbox` — which already recorded an address at `:mark_provisioned` — succeeds. That
is the intended reading: the requirement is that a `running` row has an address, not that every
transition restates one.

## 6. Fail it

```elixir
{:ok, failed} =
  sandbox
  |> Ash.Changeset.for_update(:mark_failed, %{
    reason: :template_missing,
    detail: "no template elixir-1.18 for stack :elixir"
  })
  |> Ash.update(authorize?: false)
```

Note the input names: the action takes `reason` and `detail` as **arguments**, and stores them as
`failure_reason` and `failure_detail`. `accept []` is deliberate — a caller cannot write those two
attributes directly, only through this action.

`failure_reason` is a **closed set** — `:timeout`, `:resource_cap`, `:template_missing`,
`:host_unreachable`, `:mechanism_error` — constrained on the resource. A free-text field would
satisfy the type and fail the requirement, because a caller writing `"error"` collapses all five
into one. A mechanism with a more specific cause maps to one of the five and puts its own words in
`failure_detail`, which is recorded verbatim and never interpreted.

Now try an invalid one:

```elixir
sandbox
|> Ash.Changeset.for_update(:mark_failed, %{reason: :something_went_wrong})
|> Ash.update(authorize?: false)
# => {:error, ...} invalid value for :failure_reason
```

## Where to go next

* Which of the six templates you actually need: [Choose a template](how-to/choose-a-template.md)
* Storing the credential a sandbox connects to its own database with:
  [Encrypt a credential](how-to/encrypt-a-credential.md)
* What you may call, and what may change under you: [the public interface](../priv/boundary.md)
* Actually running something: [`ex_sandbox`](https://hexdocs.pm/ex_sandbox)
