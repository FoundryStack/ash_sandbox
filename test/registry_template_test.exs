defmodule AshSandbox.RegistryTemplateTest do
  @moduledoc """
  A host `use`-ing the template gets **its own** data layer, domain, and table
  (012 T016, T017, FR-009; quickstart Scenario 5).

  ## Why this asserts the resolved data layer and not that it compiles

  ⚠️ Research R5's spike established that the falsified shape — the library
  declaring the resource, the host attaching a data layer afterward —
  **compiles cleanly and exits 0** while resolving to `Ash.DataLayer.Simple`,
  the no-persistence default. A compile-only assertion passes against the broken
  shape and proves nothing.

  So every assertion here reads back what Ash actually persisted into the beam.
  """
  use ExUnit.Case, async: true

  alias AshSandbox.HostApp.SandboxRegistry

  describe "the host's declarations win (FR-009, T016)" do
    test "the resolved data layer is the host's, not the library's default" do
      # THE test. `Ash.DataLayer.Simple` here would mean the template shape had
      # regressed into the shape R5 falsified.
      assert Ash.Resource.Info.data_layer(SandboxRegistry) == Ash.DataLayer.Ets

      refute Ash.Resource.Info.data_layer(SandboxRegistry) == Ash.DataLayer.Simple
    end

    test "the resolved domain is the host's" do
      assert Ash.Resource.Info.domain(SandboxRegistry) == AshSandbox.HostApp.Sandboxes
    end

    test "the resource is a real Ash resource" do
      assert Ash.Resource.Info.resource?(SandboxRegistry)
    end
  end

  describe "library-owned attributes are present (T017)" do
    test "owner_ref and state exist with the library's semantics" do
      names = SandboxRegistry |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

      assert :owner_ref in names
      assert :state in names
      assert :id in names
      assert :mechanism_ref in names
      assert :inserted_at in names
      assert :updated_at in names
    end

    test "owner_ref is a bare string -- any richer type invites interpretation" do
      attr = Ash.Resource.Info.attribute(SandboxRegistry, :owner_ref)

      assert attr.type == Ash.Type.String
      refute attr.allow_nil?
    end

    test "id is a string rather than a uuid, because the host generates it" do
      attr = Ash.Resource.Info.attribute(SandboxRegistry, :id)

      assert attr.type == Ash.Type.String
      assert attr.primary_key?
    end

    test "state covers the full lifecycle" do
      attr = Ash.Resource.Info.attribute(SandboxRegistry, :state)

      assert attr.constraints[:one_of] == [
               :provisioning,
               :provisioned,
               :starting,
               :running,
               :stopping,
               :stopped,
               :failed,
               :destroyed
             ]
    end

    test "lifecycle actions are generated" do
      names = SandboxRegistry |> Ash.Resource.Info.actions() |> Enum.map(& &1.name)

      for action <- [
            :provision,
            :mark_provisioned,
            :mark_starting,
            :mark_running,
            :mark_stopping,
            :mark_stopped,
            :mark_failed,
            :mark_destroyed
          ] do
        assert action in names, "missing lifecycle action #{action}"
      end
    end
  end

  describe "the library declares no multitenancy strategy (FR-003)" do
    test "a host is not forced into any multi-tenancy model" do
      # `FR-003` forbids requiring a particular multi-tenancy model. Declaring
      # `strategy: :context` in the template would impose one on every host.
      assert Ash.Resource.Info.multitenancy_strategy(SandboxRegistry) == nil
    end
  end

  describe "records actually persist (the claim R5's falsified shape could not make)" do
    test "a sandbox can be written and read back" do
      id = "sb-#{System.unique_integer([:positive])}"

      {:ok, record} =
        Ash.create(
          SandboxRegistry,
          %{id: id, owner_ref: "owner-1", environment_ref: id, template_ref: "tpl"},
          action: :provision,
          authorize?: false
        )

      assert record.state == :provisioning

      # Reading it back is what the falsified shape could never do -- with
      # `Ash.DataLayer.Simple` the create succeeds and nothing is stored.
      assert {:ok, found} = Ash.get(SandboxRegistry, id, authorize?: false)
      assert found.owner_ref == "owner-1"
    end

    test "to_sandbox/2 hands the mechanism a plain struct, not the resource" do
      id = "sb-#{System.unique_integer([:positive])}"

      {:ok, record} =
        Ash.create(
          SandboxRegistry,
          %{
            id: id,
            owner_ref: "owner-9",
            environment_ref: id,
            template_ref: "tpl",
            memory_limit_mb: 256
          },
          action: :provision,
          authorize?: false
        )

      sandbox = SandboxRegistry.to_sandbox(record, %{trace: "abc"})

      assert %ExSandbox.Sandbox{} = sandbox
      assert sandbox.owner_ref == "owner-9"
      assert sandbox.memory_limit_mb == 256
      assert sandbox.context == %{trace: "abc"}

      # Host-only fields do not cross into the mechanism's view (research R3).
      refute Map.has_key?(sandbox, :state)
      refute Map.has_key?(sandbox, :failure_reason)
      refute Map.has_key?(sandbox, :inserted_at)
    end
  end

  describe "one sandbox per environment (003-FR-010, research R7)" do
    test "a second provision for the same environment returns the first sandbox" do
      env = "env-" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, first} =
        Ash.create(SandboxRegistry, %{id: "a", owner_ref: "o", environment_ref: env},
          action: :provision,
          authorize?: false
        )

      {:ok, second} =
        Ash.create(SandboxRegistry, %{id: "b", owner_ref: "o", environment_ref: env},
          action: :provision,
          authorize?: false
        )

      # The loser gets the winner's row, not its own. Without this, the second
      # sandbox is a leak nothing will clean up -- the registry records one.
      assert second.id == first.id
    end

    test "the second provision does not overwrite the first's attributes" do
      env = "env-" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, first} =
        Ash.create(
          SandboxRegistry,
          %{id: "a", owner_ref: "o", environment_ref: env, template_ref: "elixir-1.20"},
          action: :provision,
          authorize?: false
        )

      {:ok, second} =
        Ash.create(
          SandboxRegistry,
          %{id: "b", owner_ref: "o", environment_ref: env, template_ref: "python-3.13"},
          action: :provision,
          authorize?: false
        )

      # `upsert_fields []` is why. A late arrival must not stamp its own
      # template over a sandbox already provisioned with another.
      assert second.template_ref == first.template_ref
      assert second.template_ref == "elixir-1.20"
    end

    test "different environments get different sandboxes" do
      # ⚠️ Regression pin. `environment_ref` was briefly nullable, and every
      # sandbox that omitted it shared the identity value `nil` -- so the upsert
      # matched them against each other and the second provision silently
      # returned the first. Two different owners produced one row. Requiring the
      # attribute is what prevents it; this test is what would notice.
      {:ok, a} =
        Ash.create(SandboxRegistry, %{id: "x", owner_ref: "o1", environment_ref: "env-x"},
          action: :provision,
          authorize?: false
        )

      {:ok, b} =
        Ash.create(SandboxRegistry, %{id: "y", owner_ref: "o2", environment_ref: "env-y"},
          action: :provision,
          authorize?: false
        )

      refute a.id == b.id
    end

    test "environment_ref cannot be omitted" do
      assert {:error, _} =
               Ash.create(SandboxRegistry, %{id: "z", owner_ref: "o"},
                 action: :provision,
                 authorize?: false
               )
    end
  end

  describe "record_request (restore-idle-stop 2.2)" do
    # Spec scenario, routing: "The observation time is the interval's, not the
    # writer's".
    #
    # ⚠️ THE test for this action's whole reason to exist. The obvious way to
    # write `record_request` is `change set_attribute(:last_request_at,
    # &DateTime.utc_now/0)`, which compiles, passes any test that only asserts
    # "a timestamp appeared", and is wrong: the scrape observes an interval that
    # has already closed, so the moment of the write is not the moment of the
    # request. Asserting a value the test SUPPLIED is the only assertion that
    # can tell the two implementations apart.
    test "writes the argument, not the moment of the write" do
      observed_at = ~U[2024-03-04 05:06:07.891234Z]

      {:ok, sandbox} =
        Ash.create(
          SandboxRegistry,
          %{id: "rr-1", owner_ref: "o", environment_ref: "env-rr-1"},
          action: :provision,
          authorize?: false
        )

      assert is_nil(sandbox.last_request_at)

      {:ok, recorded} =
        Ash.update(sandbox, %{observed_at: observed_at},
          action: :record_request,
          authorize?: false
        )

      assert recorded.last_request_at == observed_at
    end

    test "a later observation moves it, and the value is still the caller's" do
      {:ok, sandbox} =
        Ash.create(
          SandboxRegistry,
          %{id: "rr-2", owner_ref: "o", environment_ref: "env-rr-2"},
          action: :provision,
          authorize?: false
        )

      {:ok, first} =
        Ash.update(sandbox, %{observed_at: ~U[2024-03-04 05:00:00.000000Z]},
          action: :record_request,
          authorize?: false
        )

      {:ok, second} =
        Ash.update(first, %{observed_at: ~U[2024-03-04 05:05:00.000000Z]},
          action: :record_request,
          authorize?: false
        )

      assert second.last_request_at == ~U[2024-03-04 05:05:00.000000Z]
    end

    test "the observation time is required" do
      # An optional argument would default the attribute to nil, and a nil
      # `last_request_at` is the value the sweep reads as "never observed" --
      # so a caller that forgot the time would erase the evidence of use it was
      # called to record.
      {:ok, sandbox} =
        Ash.create(
          SandboxRegistry,
          %{id: "rr-3", owner_ref: "o", environment_ref: "env-rr-3"},
          action: :provision,
          authorize?: false
        )

      assert {:error, _} = Ash.update(sandbox, %{}, action: :record_request, authorize?: false)
    end

    test "last_request_at is nullable, because 'never requested' has to be sayable" do
      attr = Ash.Resource.Info.attribute(SandboxRegistry, :last_request_at)

      assert attr.type == Ash.Type.UtcDatetimeUsec
      assert attr.allow_nil?
    end

    test "record_request accepts no attributes directly" do
      # `accept []`. The attribute is reachable only through the argument, so
      # there is no second way to write it that could skip the semantics above.
      action = Ash.Resource.Info.action(SandboxRegistry, :record_request)

      assert action.type == :update
      assert action.accept == []
      assert [%{name: :observed_at, allow_nil?: false}] = action.arguments
    end
  end
end
