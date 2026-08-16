defmodule AshSandbox.ScopePassthroughTest do
  @moduledoc """
  The library compares two opaque scope values and never interprets either
  (003 T051, `012-FR-003`).

  ## What "never interprets" rules out

  The tempting implementation reads a field off the scope — `scope.tenant.id`,
  `actor.owner_id` — because every host the author has in mind happens to have
  one. That is a stack assumption wearing a different hat: it works for Axonn
  and fails for the Story 1 consumer who passes a bare string, a tuple, or a
  struct of their own with differently-named fields.

  So the tests below hand the library owner references of shapes it cannot
  possibly know about, and require that matching ones are admitted and
  non-matching ones refused. Equality is the entire contract.

  ## Why hostile shapes

  A value that merely *looks* structured — `"tenant:42"`, `{:owner, 7}` — is
  what tempts an implementation to parse. If any of these round-trip
  incorrectly, something is splitting, downcasing, or reaching into them.
  """
  # `async: false`: these tests share one ETS-backed registry table with the
  # other suites in this app, and a concurrent run tears it down mid-test.
  use ExUnit.Case, async: false

  alias AshSandbox.HostApp.SandboxRegistry

  # Deliberately unlike each other and unlike anything Axonn passes. A string
  # with a delimiter invites splitting; a tuple invites element access; a map
  # invites field lookup.
  @opaque_owners [
    "plain-owner",
    "tenant:42:extra",
    "../../etc/passwd",
    "  padded  ",
    "MiXeDcAsE"
  ]

  defp register(owner_ref) do
    SandboxRegistry
    |> Ash.Changeset.for_create(
      :provision,
      %{
        id: Ash.UUID.generate(),
        owner_ref: owner_ref,
        environment_ref: Ash.UUID.generate(),
        mechanism: :null
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  describe "an owner reads only its own records (FR-002)" do
    test "a matching owner_ref is admitted" do
      for owner <- @opaque_owners do
        record = register(owner)

        assert {:ok, found} =
                 SandboxRegistry
                 |> Ash.Query.for_read(:read, %{}, actor: %{owner_ref: owner})
                 |> Ash.read(),
               "owner #{inspect(owner)} could not read its own record"

        assert Enum.any?(found, &(&1.id == record.id)),
               "owner #{inspect(owner)} could not see its own record"

        # The same read, from the other side: it sees nothing belonging to
        # anyone else. ETS is not reset between iterations, so records written
        # for the other owners in this list are present and would show up.
        assert Enum.all?(found, &(&1.owner_ref == owner))
      end
    end

    test "a non-matching owner_ref reads nothing" do
      # The load-bearing direction. These resources are not schema-isolated, so
      # nothing but this policy stands between two tenants.
      for owner <- @opaque_owners do
        _record = register(owner)

        assert {:ok, found} =
                 SandboxRegistry
                 |> Ash.Query.for_read(:read, %{}, actor: %{owner_ref: "someone-else"})
                 |> Ash.read()

        refute Enum.any?(found, &(&1.owner_ref == owner)),
               "owner \"someone-else\" read a record belonging to #{inspect(owner)}"
      end
    end

    test "an owner_ref that differs only in case or whitespace is refused" do
      # Equality, not normalisation. A library that trims or downcases is
      # interpreting the value, and two owners whose references differ only in
      # case would collapse into one.
      record = register("MiXeDcAsE")

      for near_miss <- ["mixedcase", "MIXEDCASE", " MiXeDcAsE", "MiXeDcAsE "] do
        assert {:ok, found} =
                 SandboxRegistry
                 |> Ash.Query.for_read(:read, %{}, actor: %{owner_ref: near_miss})
                 |> Ash.read()

        refute Enum.any?(found, &(&1.id == record.id)),
               "#{inspect(near_miss)} matched #{inspect(record.owner_ref)}; the library is " <>
                 "normalising an opaque value rather than comparing it"
      end
    end
  end

  describe "the scope is not interpreted (012-FR-003)" do
    test "the stored owner_ref is byte-identical to what was supplied" do
      for owner <- @opaque_owners do
        record = register(owner)
        assert record.owner_ref == owner
      end
    end

    test "an actor with no owner_ref reads nothing rather than everything" do
      # Fail closed. An actor shape the library does not recognise must not be
      # treated as "no filter applies", which is how a policy silently becomes
      # a no-op.
      #
      # Ash refuses outright rather than returning an empty list, which is the
      # stronger of the two acceptable answers: the caller is told its actor was
      # rejected instead of being handed an empty result it might read as "this
      # owner has no sandboxes".
      register("some-owner")

      for unrecognised <- [%{unrelated: "field"}, %{owner_ref: nil}, nil] do
        result =
          SandboxRegistry
          |> Ash.Query.for_read(:read, %{}, actor: unrecognised)
          |> Ash.read()

        assert match?({:error, %Ash.Error.Forbidden{}}, result) or match?({:ok, []}, result),
               "actor #{inspect(unrecognised)} was neither refused nor given an empty " <>
                 "result: #{inspect(result)}"
      end
    end
  end
end
