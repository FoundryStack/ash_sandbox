# AshSandbox

Ash resources modelling sandbox lifecycle, over [`ex_sandbox`](https://hexdocs.pm/ex_sandbox).

The split point between the two libraries is **Ash itself**. A project that wants isolated
execution without Ash gets a working mechanism from `ex_sandbox` alone; this package is what Ash
users add on top — six `__using__/1` templates that give a host a sandbox registry, project,
environment, template catalogue and credential store without writing an `Ash.Domain` from scratch.

It depends on `ash` and `ex_sandbox`, and on no host application. That direction is enforced by
the `:boundary` compiler rather than by review — see [what the library promises](priv/boundary.md).

> ⚠️ **Not on Hex yet.** `0.1.0` is the extraction release. Until it is published, depend on it
> from git.

## Installation

```elixir
def deps do
  [
    {:ash_sandbox, github: "FoundryStack/ash_sandbox", tag: "v0.1.0"}
  ]
end
```

It brings `ash ~> 3.0`, `ex_sandbox ~> 1.2` and `picosat_elixir ~> 0.2`. The SAT solver is not
optional: the templates emit `Ash.Policy.Authorizer` policies, and Ash needs a solver to evaluate
them. A host that already has one gets its own.

## Documentation

| If you want to | Read |
|---|---|
| Get one sandbox record stored, start to finish | [Getting started](docs/getting-started.md) |
| Work out which of the six templates you need | [Choose a template](docs/how-to/choose-a-template.md) |
| Store a sandbox credential encrypted | [Encrypt a credential](docs/how-to/encrypt-a-credential.md) |
| Know exactly what you may call, and what may change under you | [The public interface](priv/boundary.md) |
| Understand why this ships templates rather than resources | [Why the host owns the module](docs/explanation/why-the-host-owns-the-module.md) |
| Read a `003-FR-021`-style identifier in the source | [Requirement IDs](docs/requirement-ids.md) |
| Know where this library came from | [Provenance](docs/provenance.md) |

Module documentation is generated from the source and is authoritative for behaviour. `AshSandbox`'s
own `@moduledoc` carries the public list; this README summarises it, and if the two ever disagree
the moduledoc is right.

## What is public

* `AshSandbox.RegistryTemplate` — the sandbox record itself
* `AshSandbox.ProjectTemplate` — a named grouping of environments under one `owner_ref`
* `AshSandbox.EnvironmentTemplate` — carries `target_stack`, which is what selects a mechanism
* `AshSandbox.TemplateTemplate` — the base image or release a sandbox provisions from
* `AshSandbox.OperationRecordTemplate` — lifecycle outcomes with attribution, stored rather than
  traversed
* `AshSandbox.SandboxCredentialTemplate` — the per-sandbox database role
* `AshSandbox.EncryptedSecret` — `Ash.Type` encrypting a value before it reaches the data layer;
  public **by consequence**, because a host declaring `SandboxCredentialTemplate` receives it as an
  attribute type whether or not it ever names the module

**A module not listed above is private, whether or not it is namespaced `Internal`**
(`012-FR-014`). The `AshSandbox.Internal.*` prefix makes the common case obvious; the list is what
defines the boundary, and lacking the prefix does not make a module public.

Each template's `__using__/1` **options are public interface too**, because the host writes that
call site. Changing them is a breaking change under `012-FR-015`.

⚠️ `AshSandbox.RunPolicy`, the `AshSandbox.Resource` DSL extension and `AshSandbox.Plug` were
withdrawn before extraction (R-12) and do not exist in this package. All three were correct,
tested, and reachable only from each other: the plug was the sole reader of the DSL, the DSL was
the sole route to the run policy, and no host ever mounted the plug.

## What this library does not do

It has no owner concept, no lifecycle concept, no database layout and no request-scoping type, and
it never parses `owner_ref`, `mechanism_ref` or `context` — those are stored, compared and
propagated, never interpreted. The host supplies all of it. `priv/boundary.md` lists what a
consumer must supply and why the library cannot.

**Declared limits are not enforced limits.** A `cpu_limit` on a registry row is what the host
*asked for*. Nothing inside the BEAM can enforce it; the boundary is the operating system, and
enforcement is `ex_sandbox`'s job. Where a host cannot enforce, `ExSandbox.Capability` reports the
capability unavailable and the mechanism refuses to start sandboxes rather than starting them
unconfined.

## Tests

```
mix test
```

No database and no container: the suite compiles host resources against `Ash.DataLayer.Ets` in
`test/support/host_app.ex`, because what is being tested is what the templates *emit*.

`mix precommit` is the gate — compile with warnings as errors, unused-dependency check, format
check, `mix docs --warnings-as-errors`, then the suite.

## License

Apache-2.0. See [LICENSE](https://github.com/FoundryStack/ash_sandbox/blob/main/LICENSE).
