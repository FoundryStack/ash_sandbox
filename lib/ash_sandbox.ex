defmodule AshSandbox do
  @moduledoc """
  Ash resources modelling sandbox lifecycle, over `ex_sandbox`.

  The split point between the two libraries is **Ash itself**: a project using
  the sandbox capability without Ash gets a working mechanism from
  `ex_sandbox`, and this package is what Ash users add on top. It depends on
  `ex_sandbox` and `ash`, and never on any host application (`FR-002`).

  ## Public interface

  Seven modules, and no more. `priv/boundary.md` carries the same list with a
  purpose and a stability note against each row; it ships inside the package,
  and it is the copy a consumer parses rather than one it keeps by hand.

    * `AshSandbox.RegistryTemplate` — the sandbox record itself
    * `AshSandbox.ProjectTemplate` — a named grouping of environments under one
      `owner_ref`
    * `AshSandbox.EnvironmentTemplate` — carries `target_stack`, which is what
      selects a mechanism
    * `AshSandbox.TemplateTemplate` — the base image or release a sandbox
      provisions from (`003-FR-008`)
    * `AshSandbox.OperationRecordTemplate` — lifecycle outcomes with
      attribution, stored rather than traversed (`003-FR-025`)
    * `AshSandbox.SandboxCredentialTemplate` — the per-sandbox database role
      (`003-FR-018`–`FR-021`)
    * `AshSandbox.EncryptedSecret` — `Ash.Type` encrypting a value before it
      reaches the data layer (`003-FR-021`). Public **by consequence**: a host
      declaring `SandboxCredentialTemplate` receives the type as its `secret`
      attribute's type, so it is in that host's compiled surface whether or not
      it ever names the module

  The first six are `__using__/1` templates and share one shape — **the host**
  declares data layer, repo, table, and domain. There are six rather than one
  because every resource modelled here needs the host to own its declaration
  for the same reason; "This library ships no concrete resource module" below
  is that reason.

  ⚠️ Three modules were withdrawn from this list (R-12): `AshSandbox.RunPolicy`,
  the `AshSandbox.Resource` DSL extension, and `AshSandbox.Plug`. All three were
  correct, tested, and reachable only from each other -- the plug was the sole
  reader of the DSL, the DSL was the sole route to the run policy, and no host
  in the umbrella mounted the plug. Routing is done by Caddy against
  `Axonn.Routing`, which is why removing them changes no behaviour.

  ## Everything else is private

  **A module not listed above is private, whether or not it is namespaced
  `Internal`** (`FR-014`). `AshSandbox.Internal.*` makes the common case obvious;
  the list is what defines the boundary.

  ## This library ships no concrete resource module

  It ships a **template the host `use`s**. That is not a stylistic preference —
  research R5's spike falsified the obvious alternative:

      # This compiles cleanly, exits 0, and can never store anything.
      # The library declares the resource; the host attaches a data layer after.

  `Ash.Resource.Info.data_layer/1` reads a value persisted into the resource
  module's beam **when the library compiles**. Absent a declaration it is
  `Ash.DataLayer.Simple` — permanently. The host can add the resource to its own
  domain and the whole thing builds without a warning, and nothing is ever
  written. Same failure shape as a boundary violation: it compiles, exits 0, and
  fails later.

  So the host owns the module:

      defmodule MyApp.SandboxRegistry do
        use AshSandbox.RegistryTemplate,
          data_layer: AshPostgres.DataLayer,
          domain: MyApp.Sandboxes,
          repo: MyApp.Repo,
          table: "sandboxes"
      end

  The library owns the attributes, actions, and semantics; the host owns
  storage (`FR-009`). Because of this, `__using__/1`'s options **are** public
  interface, and changing them is a breaking change under `FR-015`.

  ## Declared limits are not enforced limits

  Limits recorded on a registry record are what the host **asked for**. Nothing
  inside the BEAM can enforce them — `005` established that the boundary is the
  operating system. `ExSandbox.Hardening` enforces. Where the host cannot
  enforce, `ExSandbox.Capability` reports the capability unavailable and the
  mechanism refuses to start sandboxes rather than starting them unconfined.

  ⚠️ The `sandbox do ... end` DSL that used to carry these declarations is
  withdrawn with the modules above. The sentence it existed to qualify is not:
  a limit written anywhere in this library is a request, not a cap.

  ## Policy belongs to the host

  This library has no lifecycle concept and never asks *why* a sandbox may not
  run. ⚠️ It also no longer offers a seam for the host to answer: `FR-008`'s
  `AshSandbox.RunPolicy` was consulted only by the withdrawn plug, so Axonn's
  tenant-`active` check runs on its own routing path instead.
  """

  # `enforce-the-domain-graph`, as amended by SCR-001. This is the one place in
  # the umbrella where the `boundary` compiler is turned on, and the reason it
  # is safe here is the reason it is unsafe elsewhere: there is no `Ash.Domain`
  # module in this app to collide with `use Boundary` over the `@opts` module
  # attribute, and one boundary cannot form a cycle.
  #
  # `deps: []` with `check: [apps: [...]]` naming `:axonn` is the whole check.
  # `FR-002` and `FR-006` say nothing here may reference the host application,
  # and until now nothing enforced that: the umbrella builds every app into one
  # `_build/<env>/lib`, so `Axonn.Tenancy` is loadable from here and a
  # reference to it raises no undefined-module warning. It is now a build
  # failure. ⚠️ `:axonn` is deliberately NOT in `deps/0` -- listing it there to
  # make the check work would create the very dependency the check forbids.
  # `check.apps` is boundary's mechanism for policing an application you do not
  # depend on, which is exactly the shape of this rule.
  #
  # ⚠️ `aliases: true` is load-bearing, not decoration. MEASURED 2026-09-03: the
  # first version of this declaration omitted it, and a probe module holding
  # `@teeth_probe Axonn.Tenancy` compiled clean -- the check had no teeth
  # against the most likely way the rule gets broken, an `alias Axonn.Something`
  # at the top of a file. `Boundary.Checker` filters every reference through
  # `from_boundary.check.aliases or reference.type != :alias_reference`
  # (`deps/boundary/lib/boundary/checker.ex:166`) and `normalize_check` defaults
  # `aliases` to `false` (`deps/boundary/lib/boundary/definition.ex`). With it
  # set, the same probe fails the build: `forbidden reference to Axonn.Tenancy`.
  #
  # `exports:` is the published surface `@moduledoc` above lists, and it
  # excludes `AshSandbox.Internal.*` by naming what is public rather than by
  # denying what is not.
  use Boundary,
    deps: [],
    check: [aliases: true, apps: [axonn: :compile, axonn: :runtime]],
    exports: [
      EncryptedSecret,
      EnvironmentTemplate,
      OperationRecordTemplate,
      ProjectTemplate,
      RegistryTemplate,
      SandboxCredentialTemplate,
      TemplateTemplate
    ]
end
