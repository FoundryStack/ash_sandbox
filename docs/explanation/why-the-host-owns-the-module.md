# Why the host owns the module

This library ships six `__using__/1` templates and **no concrete resource module**. Every
integration therefore starts with the consumer writing something like this:

```elixir
defmodule MyApp.Sandbox do
  use AshSandbox.RegistryTemplate,
    data_layer: AshPostgres.DataLayer,
    domain: MyApp.Sandboxes,
    repo: MyApp.Repo,
    table: "sandboxes"
end
```

That is more work than `{:ash_sandbox, "~> 0.1"}` and a module already there. It is also the only
shape that works, and the reason is worth the page because the alternative *looks* correct and
nothing in a build will say otherwise.

## The alternative, and how it fails

The obvious design is for the library to declare the resource and the host to attach a data layer
afterward — a resource module in the package, added to the host's own domain, configured at
runtime.

It compiles. It exits 0. It can never store anything.

`Ash.Resource.Info.data_layer/1` delegates to `Extension.get_persisted(resource, :data_layer)`. The
data layer is written into the resource module's beam **when the library compiles** — not when the
host compiles, and not when the host configures. Absent a declaration it is `Ash.DataLayer.Simple`,
the no-persistence default, permanently.

So the host adds the resource to its domain, the whole thing builds without a warning, every call
returns `{:ok, _}`, and nothing is ever written. This was a spike, not a thought experiment: it was
built, and it is why the templates exist.

## Why that failure shape is the one to design against

Compiles, exits 0, fails later — the same shape as a boundary violation, and the same shape as the
packaging defect that shipped a boundary document where `Application.app_dir/2` could not reach it.
It is worth naming because it is the failure class this pair of libraries keeps meeting:

* A wrong-direction library reference compiles cleanly, passes `mix deps.tree`, and fails only at
  runtime inside a third-party consumer.
* A resource with no data layer compiles cleanly and silently stores nothing.
* A `nil` `environment_ref` makes every sandbox share one identity value and the upsert quietly
  returns the wrong row.

None of these is caught by a type, and none of them is caught by the happy path a test was written
against. The library's answer is the same each time: make the thing a **build-time** fact rather
than a runtime one. The host declares its data layer at the `use` site, so a host that has not made
the decision cannot compile.

## What follows from it

**`__using__/1`'s options are public interface.** The host writes that call site, so changing an
option name, making one required, or changing what a value means is a breaking change under
`012-FR-015` exactly as renaming a public function would be.

**There are six templates rather than one.** Every resource this library models needs the host to
own its declaration for the same reason, so each gets its own `__using__/1`. The shared part —
emitting the host's `postgres do ... end` block — lives in
`AshSandbox.Internal.DataLayerSection` and stays private, because a host on a non-PostgreSQL data
layer must never receive one.

**The library owns semantics; the host owns storage.** Attributes, actions, states, validations and
policies are the library's, and they are the same for every consumer. Table names, repos, data
layers, and where any of it physically lives are the host's, and the library never learns them.

**Data-layer independence is tested, not asserted.** `test/support/host_app.ex` binds a project, an
environment and a registry on `Ash.DataLayer.Ets` — a pretend consumer with no connection to the
application this library was extracted from. A test that could only be written against PostgreSQL
would not be testing the claim at all.

That fixture has already earned its place twice. Once when an identity without `pre_check_with`
made the environment template AshPostgres-only in practice; and again in 2026-09 when every
`mark_*` transition on the registry turned out to raise `MustBeAtomic` on ETS — the identity
pre-check adds a `before_action` hook, and any `before_action` hook makes an update non-atomic. The
fixture existed but no test had ever run an *update* against it. See
`AshSandbox.Internal.DataLayerSection.require_atomic/1`.

## The limit of the arrangement

The host owning the module does not mean the host owning the rules. A limit recorded on a registry
row — `cpu_limit`, `memory_limit_mb` — is what the host *asked for*, and nothing in this library or
anywhere else inside the BEAM can enforce it. The operating system is the boundary. Enforcement is
[`ex_sandbox`](https://hexdocs.pm/ex_sandbox)'s job, and where the host cannot enforce, its
capability check reports the capability unavailable and the mechanism refuses to start sandboxes
rather than starting them unconfined.

A library that let you write a limit and implied it was a cap would be worse than one with no
limits at all.
