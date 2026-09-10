defmodule AshSandbox.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/FoundryStack/ash_sandbox"

  def project do
    [
      app: :ash_sandbox,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      name: "AshSandbox",
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      # ⚠️ BEFORE `Mix.compilers()`, which reads backwards and is not a typo.
      # `:boundary` is not a pass over already-compiled output: its `run/1`
      # opens the ETS tables and installs the compiler tracer that `:elixir`
      # then writes every cross-module reference into, and its `after_compiler`
      # callback is what reports. MEASURED: appended after `Mix.compilers()`
      # instead, the first file `:elixir` compiled raised `the table identifier
      # does not refer to an existing ETS table` from
      # `Boundary.Mix.CompilerState.initialize_module/1` -- the tracer fires
      # before the table it writes to exists.
      #
      # From this app's time in the Axonn umbrella: it was the ONLY app there
      # with `:boundary` here, for two findings recorded against
      # `Boundary.Checker.errors/2`'s unconditional cycle detection and an
      # `@opts` attribute collision with `Spark.Dsl` -- see this module's own
      # `use Boundary` note below for the shape of the check itself.
      compilers: compilers(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AshSandbox.Application, []}
    ]
  end

  defp description do
    "Ash resources modelling sandbox lifecycle, over ex_sandbox -- templates a host " <>
      "`use`s to get a working sandbox registry, project, environment and credential " <>
      "store without writing its own Ash.Domain from scratch."
  end

  defp package do
    [
      name: "ash_sandbox",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => @source_url <> "/blob/main/CHANGELOG.md"
      },
      # `docs` and `CHANGELOG.md` ship because `docs/0`'s `extras:` names them:
      # `mix hex.publish` builds the documentation from the working directory,
      # but a consumer reading the tarball -- or anyone rebuilding docs from an
      # unpacked release -- gets a broken `extras:` without them. `priv` is
      # separately load-bearing and has its own reason: see `priv/boundary.md`.
      files: ~w(lib priv docs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      # ⚠️ Every name here is one a document has to spell out and ExDoc cannot
      # resolve, which is the exact combination that turns a correct document
      # into a failed build under `--warnings-as-errors`.
      #
      # `AshSandbox.Application` is `@moduledoc false`, and `priv/boundary.md`
      # names it in backticks in the row declaring it PRIVATE -- naming it is
      # the whole point of that row, and the strict parser that reads the table
      # requires the backticks. `ex_sandbox` hit this first and recorded it:
      # de-linking the name trades a build failure for a silent contract
      # failure, which is the worse of the two.
      #
      # The other three do not exist at all. They were withdrawn (R-12) and the
      # README, the CHANGELOG and `AshSandbox`'s own moduledoc each name them
      # to say so. An entry announcing a REMOVAL has to spell the full name, so
      # the cost of keeping the name exact is a line here.
      skip_code_autolink_to: [
        "AshSandbox.Application",
        "AshSandbox.RunPolicy",
        "AshSandbox.Resource",
        "AshSandbox.Plug"
      ],
      extras: [
        "README.md",
        "docs/getting-started.md",
        "docs/how-to/choose-a-template.md",
        "docs/how-to/encrypt-a-credential.md",
        "docs/explanation/why-the-host-owns-the-module.md",
        "priv/boundary.md",
        "CHANGELOG.md",
        "docs/requirement-ids.md",
        "docs/provenance.md"
      ],
      # Diataxis, and the grouping is the navigation: a reader who wants to
      # *do* something and a reader who wants to *understand* something are
      # looking for different pages, and one flat sidebar makes them read each
      # other's.
      groups_for_extras: [
        Tutorial: ["docs/getting-started.md"],
        "How-to": [~r{docs/how-to/}],
        Reference: ["priv/boundary.md", "CHANGELOG.md"],
        Explanation: [~r{docs/explanation/}, "docs/requirement-ids.md", "docs/provenance.md"]
      ],
      # ⚠️ `AshSandbox.Internal.*` is grouped rather than hidden. Four of the
      # five carry real reasoning in their moduledocs -- why refusing an
      # allowlist change is the honest shape, why the owner check is a filter
      # and not a bypass -- and `@moduledoc false` would delete that prose from
      # the only place a reader looks for it. The group name is what says
      # "private": `priv/boundary.md` is the contract, and being documented is
      # not being public.
      groups_for_modules: [
        Interface: [AshSandbox],
        Templates: [~r/^AshSandbox\.\w+Template$/],
        Types: [AshSandbox.EncryptedSecret],
        "Internal (private -- no compatibility promise)": [~r/^AshSandbox\.Internal\./]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Ash and `ex_sandbox`, and nothing referencing Axonn (FR-002, FR-006, T005).
  # `:boundary` only where it is declared -- see the dependency's own note. In
  # `:prod` this is the plain default list, so a consumer that never resolves
  # `:boundary` can still compile this app.
  defp compilers(env) when env in [:dev, :test], do: [:boundary] ++ Mix.compilers()
  defp compilers(_env), do: Mix.compilers()

  defp deps do
    [
      {:ash, "~> 3.0"},
      # ⚠️ `{:plug, "~> 1.16"}` was removed here with `AshSandbox.Plug` (R-12).
      # It was declared rather than borrowed for exactly the right reason --
      # the umbrella supplies `plug`, so the module compiled either way and
      # would have failed inside a consumer that had no `plug` of its own. With
      # the only module that used it gone, the declaration is the same kind of
      # invisible-here claim in the other direction.
      # Same rule as `plug` above, and the same failure mode. The templates
      # emit `Ash.Policy.Authorizer` policies (003 T050), and Ash needs a SAT
      # solver to evaluate them. The umbrella already has one via `axonn`, so
      # this compiles and passes without the line -- then raises
      # `Picosat.solve/1 is undefined` inside a consumer that has no solver of
      # its own, on their first authorized read.
      {:picosat_elixir, "~> 0.2"},
      # ⚠️ `~> 1.2`, not `~> 1.0.1`, and the minor floor is load-bearing. 1.2.0
      # adds the `address/1` callback and the loopback port publish that groups
      # 5, 8 and 9 are built on; 1.0.0 additionally shipped `boundary.md` where
      # `Application.app_dir/2` cannot reach it and `ExSandbox.LoopFormatter`
      # in `test/`, which `package/0` does not publish --
      # `library_boundary_test.exs` reads the first and two Mix tasks here name
      # the second. It was briefly an absolute path dependency while 1.2.0
      # waited on the maintainer's two-factor code; it published 2026-08-31 and
      # the path is gone, which is what `DependencyAndGateTest` refuses to let
      # regress -- a path resolves on the machine that wrote it and nowhere
      # else, and this repository is worked in git worktrees.
      {:ex_sandbox, "~> 1.2"},
      # `enforce-the-domain-graph` names three apps for this dependency and one
      # of them, `apps/sandbox_gateway`, no longer exists -- the umbrella root's
      # `releases/0` note records that its live half moved under
      # `Axonn.Routing`. This app is the third one there is, and it is the one
      # that most wants the check: FR-002 and FR-006 say nothing here may
      # reference Axonn, and until now that direction was enforced by review.
      # `AshSandbox`'s boundary declares `deps: []` and `check: [apps: [axonn:
      # ...]]`, so a reference to any `Axonn.*` module from this app fails the
      # build rather than a reader. This app is the one place the check is
      # blocked by neither of SCR-001's two findings -- it has no `Ash.Domain`
      # module and no cycle -- which is why the compiler runs here and nowhere
      # else.
      # ⚠️ `only: [:dev, :test]`, and that is the difference between checking
      # this app and taxing everyone who uses it. A `compilers:` entry is not a
      # private choice: a consumer resolving `ash_sandbox` from Hex compiles it
      # with this project file, so an unscoped `:boundary` would make an
      # internal architecture check a hard build requirement of every
      # application that depends on this one. `DependencyAndGateTest` is what
      # noticed -- its `declared_deps/0` drops anything whose `only:` excludes
      # `:prod` precisely because that is not consumer facing.
      #
      # The check loses nothing by it. `mix precommit` and `mix prepush` both
      # run in `:test` and development builds are `:dev`, so every build that
      # could introduce an upward reference still runs the compiler. Only a
      # `:prod` build skips it, and a `:prod` build is not where the reference
      # gets written.
      {:boundary, "~> 0.10", runtime: false, only: [:dev, :test]},
      # `only: :dev` for the same reason `:boundary` is scoped: a consumer
      # resolving this package from Hex compiles it with this project file, and
      # a documentation tool is not a build requirement of anything that
      # depends on this library.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # `precommit` runs `test`, and a `test` invoked from inside another command
  # inherits that command's environment -- which is `dev`, where the test
  # helpers are not compiled. Without this the gate fails on its own plumbing
  # rather than on anything it is checking.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors --force",
        "deps.unlock --check-unused",
        "format --check-formatted",
        # ⚠️ A real gate step, not a courtesy. `mix docs --warnings-as-errors`
        # rejects a broken autolink, a missing `extras:` entry and a reference
        # to a hidden module -- the three ways a documentation change breaks
        # without breaking a test. `ex_sandbox` learned this the expensive way:
        # its first push failed on a defect that had been committed and locally
        # green for two commits, because only CI ran the docs build.
        #
        # ⚠️ `cmd`, and via `MIX_ENV=dev`, because `ex_doc` is `only: :dev`
        # while `preferred_envs` puts this whole alias in `:test`. Written as a
        # plain `"docs --warnings-as-errors"` step it fails with `The task
        # "docs" could not be found` -- a gate reporting a missing task rather
        # than a documentation defect.
        "cmd env MIX_ENV=dev mix docs --warnings-as-errors",
        "test"
      ]
    ]
  end
end
