# Requirement IDs

The source in this library cites requirement identifiers throughout — `003-FR-016`, `012-FR-009`,
`029 T018`, `013-FR-014b`. There are 121 of them across 13 of the 14 modules. This page explains
what they are, so they read as citations rather than noise.

## Why they are still here

This library was extracted from a larger application whose codebase writes reasoning next to code:
moduledocs cite the requirement a decision serves, record what was **MEASURED** rather than
assumed, and mark load-bearing choices with a ⚠️. The identifiers are load-bearing in that style —
they say *which* rule a piece of code exists to satisfy, which is usually the fastest answer to
"why is this like this".

They were deliberately **not** stripped during extraction. Many sentences are built around the
citation grammatically ("`003-FR-016` requires an idle timeout on an on-demand environment, so the
validation cannot be advisory"), and mechanically removing the token would leave prose worse than
the shorthand. The tradeoff accepted here is that an outside reader meets an unfamiliar identifier
and needs this page once.

## And the name `Axonn`

The same docs mention `Axonn` — `Axonn.Routing`, `Axonn.Tenancy`,
`Axonn.Workers.IdleSandboxSweepWorker`, `Axonn.Agents.Thread.tenant_id`. That is the application
this library was extracted from. Nothing here depends on it, references it at compile time, or
needs it to run; `test/dependency_and_gate_test.exs` enforces that, and the ETS host app in
`test/support/host_app.ex` is a consumer with no connection to it at all.

The mentions are kept for the same reason the identifiers are: they name the concrete caller a
decision was measured against. "A host that sweeps idle sandboxes" is abstract; the reasoning is
easier to check when the sweeper is a real module that hit the problem. Read them as provenance,
never as a dependency. See [provenance.md](provenance.md).

## Reading one

    003 - FR - 016
    │     │     │
    │     │     └── the requirement's number within that document
    │     └──────── the kind
    └────────────── the specification the requirement belongs to

Both `003-FR-016` and `003 T050` appear; the separator carries no meaning. A trailing letter
(`013-FR-014b`, `005-FR-011a`) marks a requirement refined after its first statement. Once a
paragraph has named its specification, later citations in the same paragraph drop the prefix and
appear bare as `FR-021` — 50 of the 121 are that shorthand.

### Kinds

| Prefix | Meaning | Count |
|---|---|---|
| `FR` | Functional requirement — a rule the implementation must satisfy | 95 |
| `T` | Task — a unit of the implementation plan, e.g. `003 T050` | 23 |
| `R` | Research finding — a measurement recorded before a decision | 2 |
| `SCR` | Change request against an archived specification | 1 |

A `T` citation usually explains *when* something arrived and what it replaced. The two `R`
citations are both `R-12`, and both mark the same event: three modules — `AshSandbox.RunPolicy`,
the `AshSandbox.Resource` DSL extension, and `AshSandbox.Plug` — were withdrawn from the public
interface after `R-12` found they were correct, tested, and reachable only from each other. That
withdrawal is why a host passes its own Ash extensions or none.

`SCR-001` amends `enforce-the-domain-graph`, and is cited at `lib/ash_sandbox.ex:101` to explain
why the `boundary` compiler is switched on here and nowhere else in the originating umbrella: with
no `Ash.Domain` module in this app, `use Boundary` cannot collide over the `@opts` module
attribute, and one boundary cannot form a cycle.

## The specifications

Each number is one specification in the originating application. The count is of citations carrying that prefix; the 50 bare ones inherit whichever prefix their paragraph established. They are not distributed with this
package — the ones that matter to a reader here are summarised by the code that cites them.

| ID | Specification | Qualified cites | What it contributes to this library |
|---|---|---|---|
| `003` | sandbox-contract | 33 | The lifecycle itself: states and transitions on the registry, the operation record (`FR-025`), the per-sandbox credential (`FR-018`–`FR-021`), the template a sandbox provisions from (`FR-008`), and the idle-timeout rule (`FR-016`). |
| `012` | sandbox-libraries | 21 | **The extraction itself.** `FR-009` is the data-layer independence claim these templates exist to satisfy — the single most-cited requirement here, at 7 fully-qualified references. `FR-014`/`FR-015` define the public boundary and what breaking it means. See [boundary.md](../priv/boundary.md). |
| `013` | deployment-topology | 7 | Where a sandbox runs and what it may reach from there, including the environment's network allowlist (`FR-007`, `FR-007c`, `FR-014b`). |
| `029` | sandbox-reachability | 6 | Egress reachability: hostname allowlists and what a sandbox is permitted to resolve (`FR-011`, `FR-040`, `T018`). |
| `005` | sandbox-beam | 2 | The BEAM mechanism. Contributes the language-runtime field on a template (`FR-022`) and one allowlist rule (`FR-011a`). |
| `009` | stack-adapters | 1 | `FR-053`–`FR-057`: a template is a prebuilt stack adapter with dependencies already compiled, which is what makes `target_stack` a selector rather than a label. |
| `010` | observability | 1 | `FR-004` — the general rule behind the operation record storing outcomes rather than requiring a traversal to reconstruct them. |

## The three that explain the most

If you read only a few, these carry the reasoning that shapes the whole library:

- **`012-FR-009`** — the resources must work on any Ash data layer. It is why this library ships
  `__using__/1` templates and no concrete resource module (the data layer is persisted into the
  beam at *library* compile time — see
  [why the host owns the module](explanation/why-the-host-owns-the-module.md)), why
  `AshSandbox.Internal.DataLayerSection` is private, and why the test suite binds an ETS host app
  rather than a repo.
- **`012-FR-015`** — the public interface is seven modules and the `__using__/1` options, and
  changing any of them is a breaking change. The host writes those call sites, so an option name
  is interface in exactly the way a function name is.
- **`003-FR-016`** — an `on_demand` environment must carry an idle timeout, and an
  `always_running` one must not. It is the clearest example of the library's general posture: a
  rule the host cannot opt out of, refused at validation rather than tolerated and logged.
