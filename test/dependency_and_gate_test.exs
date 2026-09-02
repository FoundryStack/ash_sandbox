defmodule AshSandbox.DependencyAndGateTest do
  @moduledoc """
  `ash_sandbox` resolves Ash and `ex_sandbox`, never the host application
  (`012-FR-002`, `FR-006`, T005) — and its build gate is the thing that can
  catch a violation.

  ## Why this lives here and not in `axonn`

  It used to be one half of a test in `apps/ex_sandbox`, which could see both
  libraries because they were siblings in one umbrella. `ex_sandbox` is a
  published package now and cannot import a sibling's dependency tree, so the
  half about `ash_sandbox` had to move to the app it is about. The other half
  travelled with the package.

  ## Why the gate is asserted, not just the tree

  Research R2 is the reason this file has a second half. An upward reference
  from a library into its host **compiles cleanly, exits 0, and passes
  `mix deps.tree`** — the dependency list is a declaration, and a call to
  `Axonn.Repo.config()` from inside this app does not appear in it. The only
  build-time check that catches it is `--warnings-as-errors`, because the
  reference is an undefined-module warning and nothing else.

  So a green dependency assertion here means very little on its own. It means
  something once the gate that catches the case it cannot see is itself
  asserted to exist.
  """
  use ExUnit.Case, async: true

  # Named exhaustively rather than counted. A test asserting "no axonn" would
  # stay green while this app grew a web framework; one asserting a maximum
  # count would let the next dependency in as an old one left. Changing this
  # list is where the argument for a new dependency belongs.
  # ⚠️ `plug` left this list with `AshSandbox.Plug` (R-12). Removing a name is
  # the same act as adding one and belongs here for the same reason: the
  # umbrella still supplies `plug`, so nothing would have failed had the
  # declaration been left behind.
  @allowed ~w(ash ex_sandbox picosat_elixir)

  # The two that make this app a library rather than part of the host. Anything
  # reaching these is reaching upward.
  @forbidden ~w(axonn axonn_web)

  describe "the dependency declaration" do
    test "is exactly Ash, ex_sandbox and its one runtime requirement" do
      assert declared_deps() == Enum.sort(@allowed), """
      ash_sandbox's consumer-facing dependencies changed.
      Expected #{inspect(Enum.sort(@allowed))}, got #{inspect(declared_deps())}.

      `FR-002` and `FR-006` forbid this app depending on the host application.
      A dependency scoped `only: :dev` or `only: :test` is not consumer facing
      and does not belong on this list.

      Declared: #{inspect(Mix.Project.config()[:deps])}
      """
    end

    test "names neither axonn nor axonn_web" do
      leaked = Enum.filter(@forbidden, &(&1 in declared_deps()))

      assert leaked == [], """
      ash_sandbox declares #{inspect(leaked)}.

      That is the upward dependency `FR-002` exists to prevent: a consumer
      installing this library would pull the entire host application in with it.
      """
    end

    test "resolves ex_sandbox from Hex rather than from an umbrella sibling" do
      opts =
        Mix.Project.config()[:deps]
        |> Enum.find(&(elem(&1, 0) == :ex_sandbox))
        |> dep_opts()

      refute Keyword.get(opts, :in_umbrella), """
      ex_sandbox is declared `in_umbrella: true`, but it is a published package
      and `apps/ex_sandbox` no longer exists in this repository. An umbrella
      dependency here would not resolve at all — and if it did, it would mean
      the extraction had been reverted without this test being reconsidered.
      """

      refute Keyword.has_key?(opts, :path), """
      ex_sandbox is declared as a path dependency. That resolves on the machine
      that wrote it and nowhere else, which is the specific thing choosing Hex
      over a path dependency was meant to avoid.
      """
    end
  end

  describe "the build gate that catches what the tree cannot" do
    test "precommit compiles with --warnings-as-errors" do
      steps = Mix.Project.config()[:aliases] |> Keyword.fetch!(:precommit)

      assert Enum.any?(steps, &String.starts_with?(&1, "compile --warnings-as-errors")), """
      ash_sandbox's `precommit` alias does not run
      `compile --warnings-as-errors`.

      Per research R2 that flag is this app's boundary enforcement, not a style
      preference: an upward reference into the host compiles cleanly, exits 0
      and passes `mix deps.tree`, and fails only at runtime inside a consumer's
      application. Removing the flag removes the only build-time check that sees
      it, and every test in this file would stay green.

      Steps: #{inspect(steps)}
      """
    end

    test "precommit runs the suite and the formatter check" do
      steps = Mix.Project.config()[:aliases] |> Keyword.fetch!(:precommit)

      assert "test" in steps, "`precommit` does not run `test`"

      assert "format --check-formatted" in steps,
             "`precommit` does not run `format --check-formatted`. The mutating " <>
               "`format` exits 0 whatever it finds and gates nothing."
    end
  end

  defp declared_deps do
    Mix.Project.config()[:deps]
    |> Enum.reject(fn dep ->
      only = dep |> dep_opts() |> Keyword.get(:only)
      only != nil and :prod not in List.wrap(only)
    end)
    |> Enum.map(fn dep -> dep |> elem(0) |> Atom.to_string() end)
    |> Enum.sort()
  end

  defp dep_opts(dep) when is_tuple(dep) do
    case Tuple.to_list(dep) do
      [_name, opts] when is_list(opts) -> opts
      [_name, _req, opts] when is_list(opts) -> opts
      _ -> []
    end
  end
end
