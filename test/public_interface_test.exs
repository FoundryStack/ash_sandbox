defmodule AshSandbox.PublicInterfaceTest do
  @moduledoc """
  The public interface of this library is stated in four places, and this test
  is the thing that keeps them equal (`012-FR-014`, `FR-015`).

  The four are:

    1. `use Boundary`'s `exports:` in `lib/ash_sandbox.ex` — the **enforced**
       one. The `boundary` compiler fails a build on a violation of it.
    2. `priv/boundary.md`'s table — the **shipped** one. It travels inside the
       package and a consumer parses the installed copy to check its own usage.
    3. `AshSandbox`'s `@moduledoc` — the one a reader on hexdocs meets first.
    4. `README.md`'s "What is public" list — the one a reader meets before
       installing anything.

  ⚠️ They drift silently. On 2026-09-10 the moduledoc listed **one** module
  while the other three listed **seven**; nothing failed, because nothing
  compared them. A consumer reading the moduledoc would have concluded that six
  public modules were private and worked around them.

  The list is deliberately one-directional in authority: `use Boundary` is what
  the compiler enforces, so a disagreement means the prose is wrong far more
  often than the code is. But this test asserts equality rather than picking a
  winner, because a module *added* to `exports:` without being documented is
  the same defect pointing the other way — an undocumented promise is still a
  promise once someone finds it.

  The second half of this file asserts the shipped document is reachable the
  way a consumer reaches it. That check is ported from `ex_sandbox`, where its
  absence shipped a release with `boundary.md` under `docs/`: `mix hex.build`
  put the file in the tarball, `tar tzf` listed it, and `Application.app_dir/2`
  could not see it. Mix links exactly `ebin` and `priv` into an application's
  build directory. The failure is invisible from inside this repository unless
  a test goes through `app_dir/2`, because every path here is repo-relative
  during development.
  """
  use ExUnit.Case, async: true

  @doc_path "priv/boundary.md"

  @expected_count 7

  describe "the four public-interface lists" do
    test "`use Boundary` exports exactly #{@expected_count} modules" do
      assert length(boundary_exports()) == @expected_count, """
      the enforced list has changed size. Every other list in this test keys off
      it, and the count is stated in prose in the moduledoc and the README
      ("Seven modules, and no more"), so those sentences need editing too.

      Now exports: #{inspect(boundary_exports())}
      """
    end

    test "the shipped document names the same modules as `use Boundary`" do
      assert_same_set(shipped_document_modules(), boundary_exports(), @doc_path)
    end

    test "the moduledoc names the same modules as `use Boundary`" do
      assert_same_set(moduledoc_modules(), boundary_exports(), "AshSandbox's @moduledoc")
    end

    test "the README names the same modules as `use Boundary`" do
      assert_same_set(readme_modules(), boundary_exports(), "README.md")
    end

    test "every module on the public list is defined" do
      missing = Enum.reject(boundary_exports(), &match?({:module, _}, Code.ensure_loaded(&1)))

      assert missing == [],
             "exported by `use Boundary` but not defined anywhere: " <> inspect(missing)
    end

    # ⚠️ `Code.ensure_loaded?/1` cannot tell a shipped module from one compiled
    # out of `test/support` -- `elixirc_paths(:test)` puts both on the path.
    # Asserting the SOURCE FILE is under `lib/` is what does. This is the check
    # that catches a public module living somewhere `package/0` does not ship.
    test "every module on the public list is compiled from `lib/`, so `package/0` ships it" do
      unshipped =
        Enum.reject(boundary_exports(), fn module ->
          with {:module, ^module} <- Code.ensure_loaded(module) do
            module.module_info(:compile)[:source]
            |> to_string()
            |> String.contains?("/lib/")
          end
        end)

      assert unshipped == [], """
      these modules are public but are not compiled from `lib/`, so `package/0`
      does not ship them and a consumer resolving one gets `:undef`:

      #{Enum.map_join(unshipped, "\n", &"  - #{inspect(&1)}")}
      """
    end
  end

  describe "the shipped boundary document" do
    test "resolves through Application.app_dir/2, the only path a consumer has" do
      path = Application.app_dir(:ash_sandbox, @doc_path)

      assert File.exists?(path), """
      #{@doc_path} is not reachable from the built application.

      Resolved to: #{path}

      Mix links only `ebin` and `priv` into an application's build directory. If
      this document has been moved to `docs/` or anywhere else outside `priv/`,
      it still ships in the tarball and still fails here -- which is exactly the
      defect `ex_sandbox` 1.0.1 fixed. Consumers parse this file to check their
      own use of the boundary; an unreachable copy silently removes that check.
      """
    end

    test "is the module table, not an empty or truncated file" do
      content = shipped_document()

      assert content =~ "## Public interface of `ash_sandbox`",
             "the shipped document has no `## Public interface of` heading to key off"

      assert content =~ ~r/^\|\s*Module\s*\|\s*Purpose\s*\|\s*Stability\s*\|\s*$/m,
             "the shipped document has no `| Module | Purpose | Stability |` table"
    end

    test "`package/0` ships the directories the documentation lives in" do
      files = Mix.Project.config()[:package][:files]

      assert "priv" in files, """
      `package/0`'s `files:` does not list `priv`, so #{@doc_path} would not be
      published at all. The tests above pass regardless, because they read this
      repository's own build rather than an installed release.
      """

      assert "docs" in files, """
      `package/0`'s `files:` does not list `docs`, so every extra named in
      `docs/0`'s `extras:` -- the tutorial, the how-tos, the explanations --
      would be missing from the published package and every cross-link between
      them broken on hexdocs.
      """
    end
  end

  defp assert_same_set(actual, expected, source) do
    assert Enum.sort(actual) == Enum.sort(expected), """
    #{source} disagrees with `use Boundary`'s `exports:`, which is the list the
    compiler actually enforces.

    only in #{source}: #{inspect(actual -- expected)}
    missing from #{source}: #{inspect(expected -- actual)}
    """
  end

  defp boundary_exports do
    [%{opts: opts}] = Keyword.get(AshSandbox.__info__(:attributes), Boundary)

    opts
    |> Keyword.fetch!(:exports)
    |> Enum.map(&Module.concat(AshSandbox, &1))
  end

  defp shipped_document, do: Application.app_dir(:ash_sandbox, @doc_path) |> File.read!()

  defp shipped_document_modules do
    shipped_document()
    |> String.split("\n")
    # The stability cell is `Public` or a qualified variant of it -- the
    # `EncryptedSecret` row reads "Public by consequence -- see below". Matching
    # the word rather than the whole cell keeps that row on the list, which is
    # right: public by consequence is still public.
    |> Enum.filter(&Regex.match?(~r/^\|.*\|\s*Public\b[^|]*\|\s*$/, &1))
    |> Enum.flat_map(&modules_in(Enum.at(String.split(&1, "|"), 1, "")))
  end

  defp moduledoc_modules do
    {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(AshSandbox)

    moduledoc
    |> section("## Public interface")
    |> bullet_leaders()
  end

  defp readme_modules do
    Path.join(__DIR__, "../README.md")
    |> File.read!()
    |> section("## What is public")
    |> bullet_leaders()
  end

  # Everything between a heading and the next one at the same level.
  defp section(text, heading) do
    [_, rest] = String.split(text, heading, parts: 2)
    rest |> String.split(~r/^## /m, parts: 2) |> hd()
  end

  # Only the FIRST module named in each bullet: a bullet's prose cites others
  # (`Ash.Type`, `SandboxCredentialTemplate`) that are not themselves list
  # entries. Continuation lines are indented and carry no bullet marker, so
  # keying off the marker skips them.
  defp bullet_leaders(section) do
    section
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*\*\s+`(AshSandbox\.[A-Za-z0-9_.]+)`/, line) do
        [_, module] -> [Module.concat([module])]
        nil -> []
      end
    end)
  end

  defp modules_in(cell) do
    Regex.scan(~r/`(AshSandbox\.[A-Za-z0-9_.]+)`/, cell)
    |> Enum.map(fn [_, module] -> Module.concat([module]) end)
  end
end
