# The public interface of `ash_sandbox`

This document owns the **package** contract: what this library promises its consumers, and what a
consumer may rely on. It is the artifact `012-FR-014` requires — the statement of what is public.

**The list below is the boundary.** A module not named here is private, whether or not it is
namespaced `Internal` (`012-FR-014`). The `AshSandbox.Internal.*` prefix makes the common case
obvious, but the list is what defines the boundary — lacking the prefix does not make a module
public. There is no compatibility promise for a private module, and calling one from a consuming
application is the coupling `012-FR-004` forbids.

⚠️ **This file ships inside the package and is read at runtime**, via
`Application.app_dir(:ash_sandbox, "priv/boundary.md")`. A consumer can therefore check its own
usage against the real list mechanically instead of trusting a copy: parse the table below and
fail on any reference to a module it does not name. Removing this file from `package/0`'s `files:`
would silently remove every consumer's ability to run that check. `priv/`, not `docs/`: Mix links
only `ebin` and `priv` into a consumer's build directory, so a file shipped anywhere else is
present in the tarball and unreachable at runtime — `ex_sandbox` 1.0.0 made exactly this mistake
and 1.0.1 is the release that fixed it. This file starts in the right place.

If this document and `AshSandbox`'s own `@moduledoc` ever disagree, the moduledoc is right; open
an issue, because one of them has drifted.

This table used to live at
`docs/legacy/specify/012-sandbox-libraries/contracts/boundary.md` in the Axonn umbrella, alongside
an equivalent table for `ex_sandbox`. That table moved to `ex_sandbox`'s own `priv/boundary.md`
when it was extracted; this is the same move for the library that stayed behind until now.

---

## Public interface of `ash_sandbox`

| Module | Purpose | Stability |
|---|---|---|
| `AshSandbox.RegistryTemplate` | `__using__/1` template for the sandbox record; **the host** declares data layer, repo, table, domain | Public |
| `AshSandbox.ProjectTemplate` | Same shape; a named grouping of environments under one `owner_ref` | Public |
| `AshSandbox.EnvironmentTemplate` | Same shape; carries `target_stack`, which is what selects a mechanism | Public |
| `AshSandbox.TemplateTemplate` | Same shape; the base image/release a sandbox provisions from (`003-FR-008`) | Public |
| `AshSandbox.OperationRecordTemplate` | Same shape; lifecycle outcomes with attribution stored, not traversed (`003-FR-025`) | Public |
| `AshSandbox.SandboxCredentialTemplate` | Same shape; the per-sandbox database role (`003-FR-018`–`FR-021`) | Public |
| `AshSandbox.EncryptedSecret` | `Ash.Type` encrypting a value before it reaches the data layer (`003-FR-021`) | Public by consequence — see below |
| `AshSandbox.Application`, anything under `AshSandbox.Internal.*` | Implementation | **Private** |

**`EncryptedSecret` is public by consequence.** A host that declares `SandboxCredentialTemplate`
receives the type as its `secret` attribute's type, so it is already in the host's compiled
surface whether or not it names the module — the same reasoning that makes
`ExSandbox.Conformance.*` public by consequence in `ex_sandbox`'s own contract.

The compatibility promise attaches to the **stored format** (`iv <> tag <> ciphertext`, Base64) and
to the configuration key, because changing either strands every row already written. Note what is
*not* promised: the type protects a value at rest, and `sensitive? true` on the attribute protects
it in inspect output, but neither covers an `Ash.Changeset` inspected in flight.

**Three modules withdrawn (R-12) do not appear above and never will under those names**:
`AshSandbox.RunPolicy`, the `AshSandbox.Resource` DSL extension, and `AshSandbox.Plug`. All three
were correct, tested, and reachable only from each other — the plug was the sole reader of the
DSL, the DSL was the sole route to the run policy, and no host in the umbrella this library was
extracted from ever mounted the plug; routing there is done by a reverse proxy against the host's
own routing layer. A `sandbox do ... end` DSL block does not exist to withdraw further: limits
recorded on a registry record are a request the host makes of its own mechanism, never something
this library can enforce — nothing inside the BEAM can enforce a resource limit, and the operating
system is the actual boundary.

The library ships **no concrete Ash resource module**. A library-declared resource has its data
layer frozen into the beam at library compile time — the host cannot attach one afterward, and the
attempt compiles cleanly while silently producing an unpersistable resource. Each template's
`__using__/1` options are therefore public interface, and changing them is a breaking change.

That is why there are six templates rather than one: every resource this library models needs the
host to own its declaration for the same reason, so each gets its own `__using__/1`. The shared
part — emitting the host's `postgres do ... end` block — lives in
`AshSandbox.Internal.DataLayerSection` and stays **private**, because a host on a non-Postgres data
layer must never receive one.

A module not listed as public is private, whether or not it is namespaced `Internal`. `FR-014`
requires this be documented; the `Internal` namespace makes the common case obvious.

---

## What a consumer must supply

| Consumer supplies | Why the library cannot | Requirement |
|---|---|---|
| `owner_ref` value | It has no owner concept | `FR-007` |
| Run policy | It has no lifecycle concept | `FR-008` |
| Data layer, repo, storage placement | It has no database layout | `FR-009` |
| Scope/context value, or `nil` | It has no request-scoping type | `FR-003` |
| Mechanism selection and configuration | The host decides what it can run | `003` R1 |

A consumer supplying none of these beyond a mechanism gets a working sandbox — that is Story 1's
claim, and `SC-001` is its test.

---

## What the library promises

1. **No upward dependency.** This library references no module it does not declare or depend on —
   least of all a host application, since it has none. Enforced by `--warnings-as-errors` and, in
   this app alone, the `:boundary` compiler — see below.
2. **No interpretation of opaque values.** `owner_ref`, `mechanism_ref`, and `context` are stored,
   compared, and propagated; never parsed, and never used to make a decision.
3. **Capability honesty.** Declared limits are requests, not enforcement; enforcement is
   `ex_sandbox`'s job against the operating system.
4. **Versioned breakage** (`FR-015`). A change to anything listed public above is a major version.

---

## How the boundary is enforced

`AshSandbox`'s `use Boundary` (in `lib/ash_sandbox.ex`) declares `exports:` as exactly the public
list above and `check: [apps: [axonn: :compile, axonn: :runtime]]` — a compile-time failure the
moment this library references the application it was extracted from, not just a review
convention. It is scoped `only: [:dev, :test]` in `mix.exs` so resolving this package from Hex
never forces the check on a consumer; every build that could introduce the violation it exists to
catch — `mix precommit`, `mix prepush`, ordinary `mix test` — still runs it.
