defmodule AshSandbox do
  @moduledoc """
  Ash resources modelling sandbox lifecycle, over `ex_sandbox`.

  The split point between the two libraries is **Ash itself**: a project using
  the sandbox capability without Ash gets a working mechanism from
  `ex_sandbox`, and this package is what Ash users add on top. It depends on
  `ex_sandbox` and `ash`, and never on any host application (`FR-002`).

  ## Public interface

    * `AshSandbox.RegistryTemplate` — `__using__/1` template; **the host**
      declares data layer, repo, table, and domain
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
end
