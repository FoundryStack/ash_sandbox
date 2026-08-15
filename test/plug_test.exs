defmodule AshSandbox.PlugTest do
  @moduledoc """
  The routing plug fails closed (012 T042, `006` R4/R6/R7).

  The lookup here is un-scoped by nature — the tenant is not known until it
  resolves — so a wrong answer crosses a tenant boundary rather than merely
  erroring. Each test below covers one row of `006` R4's decision table, and the
  row that matters most is the last: a lookup that *errored* must refuse.
  """
  use ExUnit.Case, async: false

  alias AshSandbox.HostApp.SandboxRegistry

  @opts AshSandbox.Plug.init(registry: SandboxRegistry)

  defp conn(host) do
    %Plug.Conn{host: host, adapter: {Plug.Adapters.Test.Conn, :...}}
    |> Map.put(:state, :unset)
  end

  defp register!(hostname) do
    Ash.create!(
      SandboxRegistry,
      %{
        id: "sb-" <> Integer.to_string(System.unique_integer([:positive])),
        owner_ref: hostname,
        environment_ref: "env-" <> hostname,
        template_ref: "elixir-1.20"
      },
      action: :provision
    )
  end

  describe "the authorizing row: resolved and runnable (006 R4)" do
    test "assigns the sandbox and does not halt" do
      hostname = "app-#{System.unique_integer([:positive])}.example.com"
      register!(hostname)

      result = AshSandbox.Plug.call(conn(hostname), @opts)

      refute result.halted
      assert %ExSandbox.Sandbox{owner_ref: ^hostname} = result.assigns.sandbox
    end

    test "the assigned value is a plain struct, not the Ash record" do
      hostname = "plain-#{System.unique_integer([:positive])}.example.com"
      register!(hostname)

      sandbox = AshSandbox.Plug.call(conn(hostname), @opts).assigns.sandbox

      # ex_sandbox has no Ash dependency (FR-001), so what crosses the boundary
      # must be the plain struct.
      assert sandbox.__struct__ == ExSandbox.Sandbox
      refute Map.has_key?(sandbox, :state)
    end
  end

  describe "the refusing rows (006 R4)" do
    test "an unregistered hostname is refused" do
      result = AshSandbox.Plug.call(conn("nobody.example.com"), @opts)

      assert result.halted
      assert result.status == 404
      assert result.private.ash_sandbox_refusal == :unregistered
    end

    test "a registered hostname whose run policy refuses is refused" do
      hostname = "delinquent-#{System.unique_integer([:positive])}.example.com"
      opts = AshSandbox.Plug.init(registry: AshSandbox.HostApp.RefusingRegistry)

      Ash.create!(
        AshSandbox.HostApp.RefusingRegistry,
        %{
          id: "sb-" <> Integer.to_string(System.unique_integer([:positive])),
          owner_ref: hostname,
          environment_ref: "env-" <> hostname,
          template_ref: "elixir-1.20"
        },
        action: :provision
      )

      # The record resolves perfectly well. The host has simply said no, and
      # `AshSandbox.RunPolicy` is where that answer lives (FR-008) -- the
      # library has no lifecycle concept of its own to consult.
      assert {:error, :not_runnable} = AshSandbox.Plug.resolve(hostname, opts)

      result = AshSandbox.Plug.call(conn(hostname), opts)
      assert result.halted
      assert result.private.ash_sandbox_refusal == :not_runnable
    end

    test "a lookup that raises is refused, not authorized" do
      # 006 R4's last row, and the one most likely to be written the other way.
      # A registry module with no Ash resource behind it makes the read raise.
      opts = AshSandbox.Plug.init(registry: AshSandbox.HostApp.ExplodingRegistry)

      assert {:error, :lookup_failed} =
               AshSandbox.Plug.resolve("anything.example.com", opts)
    end

    test "a non-binary hostname is refused" do
      assert {:error, :unregistered} = AshSandbox.Plug.resolve(nil, @opts)
    end
  end

  describe "refusals are uniform (006 R4)" do
    test "unknown and uncertain produce the same status and body" do
      unknown = AshSandbox.Plug.call(conn("nobody.example.com"), @opts)

      exploding_opts = AshSandbox.Plug.init(registry: AshSandbox.HostApp.ExplodingRegistry)
      uncertain = AshSandbox.Plug.call(conn("anything.example.com"), exploding_opts)

      # A refusal that distinguishes "no such hostname" from "exists but
      # forbidden" is a hostname oracle: it tells an unauthenticated caller
      # which tenants exist.
      assert unknown.status == uncertain.status
      assert unknown.resp_body == uncertain.resp_body
    end

    test "the reason is available to the host but not in the response" do
      result = AshSandbox.Plug.call(conn("nobody.example.com"), @opts)

      assert result.private.ash_sandbox_refusal in AshSandbox.Plug.refusal_reasons()
      refute result.resp_body =~ "unregistered"
    end
  end

  describe "no route caching (006 R7)" do
    test "a second lookup re-reads rather than reusing the first answer" do
      hostname = "mutable-#{System.unique_integer([:positive])}.example.com"
      record = register!(hostname)

      assert {:ok, _} = AshSandbox.Plug.resolve(hostname, @opts)

      Ash.destroy!(record)

      # A stale route here is a cross-tenant breach, not a correctness bug: the
      # next tenant to claim this hostname would receive the previous tenant's
      # sandbox.
      assert {:error, :unregistered} = AshSandbox.Plug.resolve(hostname, @opts)
    end

    test "the plug source declares no cache" do
      source = File.read!("lib/ash_sandbox/plug.ex")

      # Blunt on purpose. 006 R7 records that caching this lookup is the
      # optimisation someone adds later without recognising its failure mode.
      refute source =~ ~r/:ets\.(new|insert|lookup)/,
             "the plug caches routes. 006 R7 forbids it absent invalidation " <>
               "atomic with the registration change."

      refute source =~ ~r/Cachex|:persistent_term/,
             "the plug caches routes (006 R7)"
    end
  end

  describe "check_origin is a dynamic lookup, never a relaxation (006 R6)" do
    test "a registered origin is allowed" do
      hostname = "ws-#{System.unique_integer([:positive])}.example.com"
      register!(hostname)

      assert AshSandbox.Plug.origin_allowed?("https://#{hostname}", @opts)
    end

    test "an unregistered origin is not allowed" do
      refute AshSandbox.Plug.origin_allowed?("https://evil.example.com", @opts)
    end

    test "a malformed origin is not allowed" do
      # `check_origin: false` would satisfy FR-012 and open cross-origin
      # WebSocket hijacking against every tenant. This is the lookup that
      # replaces it, so it must refuse what it cannot parse.
      refute AshSandbox.Plug.origin_allowed?("not a uri", @opts)
      refute AshSandbox.Plug.origin_allowed?("", @opts)
    end
  end
end
