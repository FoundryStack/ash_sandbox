# AshSandbox

Ash resources modelling sandbox lifecycle, over [`ex_sandbox`](../ex_sandbox).

The split point between the two libraries is **Ash itself**: a project using the sandbox
capability without Ash gets a working mechanism from `ex_sandbox`, and this package is what Ash
users add on top. It depends on `ex_sandbox` and `ash`, and never on any host application
(`012-FR-002`).

> ⚠️ **Not published.** `012-FR-013` is deferred; there is no Hex package yet.

## This library ships no concrete resource module

It ships a **template the host `use`s** — and that is a measured decision, not a stylistic one.
Research R5's spike falsified the obvious alternative:

```elixir
# This compiles cleanly, exits 0, and can never store anything.
# The library declares the resource; the host attaches a data layer after.
```

`Ash.Resource.Info.data_layer/1` reads a value persisted into the resource module's beam **when
the library compiles**. Absent a declaration it is `Ash.DataLayer.Simple` — permanently. The host
can add the resource to its own domain and the whole thing builds without a warning, and nothing
is ever written. Same failure shape as a boundary violation: it compiles, exits 0, and fails
later.

So the host owns the module:

```elixir
defmodule MyApp.SandboxRegistry do
  use AshSandbox.RegistryTemplate,
    data_layer: AshPostgres.DataLayer,
    domain: MyApp.Sandboxes,
    repo: MyApp.Repo,
    table: "sandboxes"
end
```

## What is public

* `AshSandbox.RegistryTemplate` — `__using__/1` template; **the host** declares data layer, repo,
  table, and domain

⚠️ `AshSandbox.RunPolicy`, the `AshSandbox.Resource` DSL extension and
`AshSandbox.Plug` were withdrawn (R-12). They were reachable only from each
other and no host mounted the plug; routing is Caddy's, against `Axonn.Routing`.

**A module not listed above is private, whether or not it is namespaced `Internal`**
(`012-FR-014`). `AshSandbox.Internal.*` makes the common case obvious; the list is what defines
the boundary.

The authoritative list lives in `AshSandbox`'s own `@moduledoc`. This README summarises it; if the
two disagree, the moduledoc is right.
