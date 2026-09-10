# Why this library cites documents that are not in it

`ash_sandbox` was an application inside the Axonn umbrella until it was moved out with
`git subtree split`, so that its 31 commits came with it. The code came. The specification tree it
was written against did not, because that tree describes a platform this library models one slice
of.

The comments and docstrings here cite that tree constantly, and deliberately. This project's
convention is that a claim about behaviour names the thing that measured it, so a comment saying
every `mark_*` transition raises `MustBeAtomic` on ETS names the date it was measured and the
fixture it was measured on. Stripping those citations during extraction would have converted
measured statements into assertions, which is the change this codebase is least willing to make.
They were kept instead, and this page is what makes them resolvable.

[requirement-ids.md](requirement-ids.md) is the companion: it decodes the identifiers themselves
and lists the seven specifications they belong to.

## 1. What stayed in the umbrella

Reachable only in the originating repository. Cited for provenance, never as something a reader of
this package is expected to open.

**The specification tree.** `openspec/specs/`, and the frozen `docs/legacy/specify/NNN-name/`
bundles behind it — `003-sandbox-contract`, `012-sandbox-libraries`, and the five others in
[requirement-ids.md](requirement-ids.md). Every `003-FR-016`-shaped token in `lib/` resolves there
and nowhere else.

**Host modules named as callers.** Eleven mentions across four files:

| Named | Where | Why it is named |
|---|---|---|
| `Axonn.Routing`, `Axonn.Tenancy` | `lib/ash_sandbox.ex` | The withdrawn `AshSandbox.Plug` and `AshSandbox.RunPolicy` did the host's tenant-`active` check; these are what took the work back when `R-12` withdrew them. |
| `Axonn.Workers.IdleSandboxSweepWorker` | `lib/ash_sandbox/registry_template.ex` | The concrete reader of `idle_timeout_seconds`. A timeout the library stores and never acts on needs an actor named, or the field looks like enforcement. |
| `Axonn.Workers.RequestActivityScrapeWorker` | `lib/ash_sandbox/registry_template.ex` | The concrete writer behind `:record_request` — the reason that action carries an unconditional `require_atomic? false` with its own justification. |
| `Axonn.Sandbox.EnvironmentAllowlistUpdateTest` | `lib/ash_sandbox/registry_template.ex` | The umbrella-side test that established the live-sandbox allowlist refusal. |
| `Axonn.Agents.Thread.tenant_id` | `lib/ash_sandbox/internal/copy_owner_ref_from_project.ex` | The shape `owner_ref` was modelled on. |
| `Axonn` (unqualified) | `lib/ash_sandbox/project_template.ex` | Names who supplies the tenant id, and who declares the `belongs_to` this library refuses to have (`012-FR-007`). |

⚠️ **A citation is not a dependency.** Nothing in this library reads any of these at build time or
at run time, and no consumer needs them. `test/dependency_and_gate_test.exs` asserts the dependency
tree, and `test/support/host_app.ex` is a host with no relationship to Axonn at all — it binds the
project, environment and registry templates onto `Ash.DataLayer.Ets`, which is the point: a suite
that could only run against the originating application's PostgreSQL would not be testing
`012-FR-009`.

That fixture is also the only reason the ETS `MustBeAtomic` defect was found — and it was added
on 2026-08-16 and the defect surfaced on 2026-09-10, because for those weeks every test that used
it read or created, and none ever ran an *update* through it.

## 2. Every file pointer here resolves

Unlike the specification citations, the backticked *filenames* in `lib/` all resolve inside this
repository:

* `priv/boundary.md` — the shipped public-interface document, read at runtime by consumers through
  `Application.app_dir/2`.
* `config/test.exs` — holds the fixed encryption key the `AshSandbox.EncryptedSecret` tests use.
* `test/ash_sandbox/encrypted_secret_test.exs` — the sole caller of the `@doc false` key accessor,
  and the reason that accessor is public at all.
* `deps/boundary/lib/boundary/definition.ex` — a dependency's source, present after `mix deps.get`.
  It is cited because the `Boundary` module attribute's persistence is not documented anywhere
  else.

There is deliberately no allowlist mechanism for absent files here, because there are no absent
files to allow. If that changes, `ex_sandbox`'s `test/documentation_pointers_test.exs` is the shape
to copy.

## 3. What the umbrella still holds

`apps/ash_sandbox/` remains in the originating repository during the extraction, and will be
deleted from it once this package is depended on rather than path-referenced. Until then the two
trees are the same code; this one is the copy that gets released.

The direction of the relationship is the thing to keep straight: **Axonn depends on this library,
and this library depends on nothing of Axonn's.** A reference pointing the other way compiles
cleanly, passes `mix deps.tree`, and fails only at runtime inside a third-party consumer, which is
why the dependency test exists rather than a convention.
