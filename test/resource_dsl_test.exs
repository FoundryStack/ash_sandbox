defmodule AshSandbox.ResourceDslTest do
  @moduledoc """
  The `sandbox do ... end` block records what a host asked for (012 T027).

  Every assertion here is about a **declaration**. None of it is evidence that
  a limit is in force — `ExSandbox.Hardening` enforces, and only
  `ExSandbox.Conformance` (by breaching the cap) establishes that it did.
  """
  use ExUnit.Case, async: true

  alias AshSandbox.HostApp.SandboxRegistry
  alias AshSandbox.Resource.Info

  test "the declared mechanism and run policy are readable" do
    assert Info.mechanism(SandboxRegistry) == AshSandbox.HostApp.NullMechanism
    assert Info.run_policy(SandboxRegistry) == AshSandbox.HostApp.AlwaysAllow
  end

  test "declared_limits/1 returns the shape ExSandbox.Hardening takes" do
    assert Info.declared_limits(SandboxRegistry) == %{
             cpu_millicores: 500,
             memory_mb: 256,
             disk_mb: 1024
           }
  end

  test "the idle timeout is recorded, and reclamation is left to the host" do
    assert Info.idle_timeout_seconds(SandboxRegistry) == 900
  end

  test "a resource declaring nothing yields empty limits rather than defaults" do
    # Inventing a default cap would be worse than none: the host would believe a
    # limit it never asked for was in force.
    assert Info.declared_limits(AshSandbox.HostApp.BareRegistry) == %{}
    assert Info.mechanism(AshSandbox.HostApp.BareRegistry) == nil
    assert Info.run_policy(AshSandbox.HostApp.BareRegistry) == nil
  end

  describe "run policy is the host's decision (FR-008)" do
    test "a permissive host proceeds" do
      sandbox = %ExSandbox.Sandbox{id: "s1", owner_ref: "o1", template_ref: "t1"}

      assert :ok = AshSandbox.RunPolicy.check(AshSandbox.HostApp.AlwaysAllow, sandbox)
    end

    test "a refusing host's reason is passed through verbatim, not interpreted" do
      sandbox = %ExSandbox.Sandbox{id: "s1", owner_ref: "o1", template_ref: "t1"}

      assert {:error, {:owner_delinquent, "invoice 42 unpaid"}} =
               AshSandbox.RunPolicy.check(AshSandbox.HostApp.RefuseAll, sandbox)
    end

    test "no policy means the host declined to have an opinion, which is permission" do
      sandbox = %ExSandbox.Sandbox{id: "s1", owner_ref: "o1", template_ref: "t1"}

      assert :ok = AshSandbox.RunPolicy.check(nil, sandbox)
    end
  end
end
