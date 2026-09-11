# Changelog

## 0.1.2 — 2026-09-11

**0.1.1's fix was incomplete and still crashed.** It wrapped `use Boundary` in a plain
`if Code.ensure_loaded?(Boundary) do use Boundary, ... end`, which does not work: `use` inside a
plain `if` still expands at compile time regardless of the branch (confirmed against Elixir 1.20.2
with an isolated `elixirc` repro naming a nonexistent module). Any `:dev`/`:test` consumer that does
not itself depend on `:boundary` still hit `module Boundary is not loaded and could not be found`.

`use Boundary` is now wrapped in `Code.eval_quoted/3`, which genuinely defers macro expansion until
the `if` branch runs.

## 0.1.1 — 2026-09-10

**Fixed: every consumer's `:dev`/`:test` build failed to compile this package.**
`compilers/1` (mix.exs) and `AshSandbox`'s `use Boundary` declaration both ran unconditionally
whenever the GLOBAL `Mix.env()` was `:dev` or `:test` — which is every umbrella app's env, not just
this package's own. `:boundary` is `only: [:dev, :test]` on this package's own deps, scoped there so
a consumer never has to resolve it; a first real Hex consumer hit `module Boundary is not loaded and
could not be found` at `lib/ash_sandbox.ex:130` the moment it built in `:dev`, because nothing made
either use of `Boundary` conditional on the module actually being present.

Both are now gated on `Code.ensure_loaded?(Boundary)`. `use Boundary` additionally moved into a
`Code.eval_quoted/3` block — `use` inside a plain `if` still expands unconditionally at compile time
(confirmed against Elixir 1.20.2), so wrapping it in `if` alone does not defer it.

## 0.1.0 — 2026-09-10

Extracted from the Axonn umbrella (`apps/ash_sandbox`) into a standalone package, carrying its
full commit history via `git subtree split`. No behavior changed by the extraction itself.

Public interface at extraction: `AshSandbox.RegistryTemplate`, `AshSandbox.ProjectTemplate`,
`AshSandbox.EnvironmentTemplate`, `AshSandbox.TemplateTemplate`,
`AshSandbox.OperationRecordTemplate`, `AshSandbox.SandboxCredentialTemplate`, and
`AshSandbox.EncryptedSecret` (public by consequence). See `priv/boundary.md` for the full contract.

`AshSandbox.RunPolicy`, the `AshSandbox.Resource` DSL extension, and `AshSandbox.Plug` were
withdrawn from the umbrella before extraction (R-12) and do not exist in this package.

### Fixed during extraction

**Update actions raised `MustBeAtomic` on every non-PostgreSQL data layer.** MEASURED 2026-09-10:
each of the registry's seven `mark_*` transitions and the project's `:rename` failed on
`Ash.DataLayer.Ets`, while passing on PostgreSQL. An identity carrying `pre_check_with` makes Ash
add an `eager_validate_identities` `before_action` hook, and any `before_action` hook makes an
update non-atomic. This falsified `012-FR-009`, the data-layer independence these templates exist
to provide — and no test had caught it, because the ETS host app in `test/support/host_app.ex` had
only ever been read from and created through, never updated through.

`AshSandbox.Internal.DataLayerSection.require_atomic/1` now emits `require_atomic?(false)` for
every data layer except `AshPostgres.DataLayer`, which keeps the atomicity `expr(now())` buys where
it is available. `:record_request` is unchanged: it already carried an unconditional
`require_atomic? false` for its own reason.

### Documentation

The package now ships a Diátaxis documentation set under `docs/`, published as ExDoc extras: a
`getting-started` tutorial executed as a test (`test/getting_started_doc_test.exs`), two how-to
guides, an explanation of why the host owns the resource module, and reference pages decoding the
requirement IDs and the citations to the originating umbrella.

`test/public_interface_test.exs` asserts that the four statements of the public interface —
`use Boundary`'s `exports:`, `priv/boundary.md`, the `AshSandbox` moduledoc, and the README — name
the same seven modules, and that the shipped boundary document resolves through
`Application.app_dir/2`. The moduledoc had drifted to naming one module of the seven.

`mix precommit` now runs `mix docs --warnings-as-errors`.
