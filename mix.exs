defmodule AshSandbox.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_sandbox,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AshSandbox.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Ash and `ex_sandbox`, and nothing referencing Axonn (FR-002, FR-006, T005).
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
      {:ex_sandbox, "~> 1.2"}
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
        # No `deps.unlock --check-unused` here. This app's `lockfile` points at
        # the umbrella's SHARED `../../mix.lock`, so the check can only ever be
        # meaningful when run against every app's `deps()` at once -- which is
        # exactly what root `mix.exs`'s own `precommit` alias does, and its gate
        # already covers this file. Run scoped to just this directory (as CI's
        # library-boundary job does, deliberately, so a root-level `deps.get`
        # doesn't leave this child unlocked) it sees only `deps/0` below and
        # reports every package the REST of the umbrella needs -- phoenix,
        # ash_postgres, oban, all of it -- as unused. Not flaky: MEASURED, it
        # fails 100% of the time. It used to "pass" here because the alias ran
        # the mutating `deps.unlock --unused` instead, which -- per the root
        # `mix.exs` comment on the same anti-pattern -- exits 0 regardless of
        # what it finds and so was never actually gating anything.
        # ⚠️ It was listed twice, which did nothing the once did not.
        "format --check-formatted",
        "test"
      ]
    ]
  end
end
