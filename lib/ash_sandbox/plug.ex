defmodule AshSandbox.Plug do
  @moduledoc """
  Resolves a hostname to a sandbox, failing closed (012 T042, `006` R4/R6/R7).

  ## Why this plug is unlike every other plug in a tenant-scoped system

  Everything else in Axonn takes an explicit scope. This cannot: the tenant is
  **not known until the lookup resolves**, so the lookup itself runs un-scoped.
  That makes it the one place where getting the answer wrong crosses a tenant
  boundary rather than merely erroring, and `006` governs it accordingly.

  Three rules follow, each of which is easy to violate with a change that looks
  like an improvement.

  ## 1. No route caching (`006` R7)

  There is no cache here and no option to enable one. A hostname→sandbox route
  is a single indexed query; a stale one is **a cross-tenant data breach** —
  requests for tenant B's domain reaching tenant A's sandbox — which inherits
  Principle I's severity, not a correctness bug's.

  `006` R7 records this precisely because caching a hot lookup is the
  optimisation someone adds later without recognising what its failure mode is.
  A cache is admissible only with invalidation in the same transaction as the
  registration change, which is the host's to build, with the host's
  transaction.

  ## 2. Uniform refusal for unknown *and* uncertain (`006` R4)

  The decision table permits exactly one authorizing row:

  | Condition | Decision |
  |---|---|
  | Resolved, sandbox runnable | **Authorize** |
  | No such hostname | Refuse |
  | Resolved, sandbox not runnable | Refuse |
  | Lookup errored or timed out | **Refuse** |

  The last row is the one most likely to be written the other way. A database
  blip must not become an access window. The refusal is *uniform* — same status,
  same body, no timing tell — because a distinguishable refusal for "unknown"
  versus "exists but forbidden" is a hostname oracle. The reason is recorded in
  `conn.private` for the host's telemetry, never rendered.

  ## 3. `check_origin` is a dynamic MFA, never `false` (`006` R6)

  Custom domains are attached at runtime, so a static `check_origin` list cannot
  contain them. The wrong fix — `check_origin: false` — satisfies the
  requirement and opens cross-origin WebSocket hijacking against every tenant.
  `origin_allowed?/2` is the MFA target: same guarantee, runtime-sourced
  allowlist.

  ## Usage

      plug AshSandbox.Plug,
        registry: MyApp.SandboxRegistry,
        domain: MyApp.Sandboxes,
        on_refusal: {MyApp.Router, :refuse, []}

  On success the sandbox is assigned to `conn.assigns.sandbox` as an
  `ExSandbox.Sandbox` struct and the connection continues.
  """
  @behaviour Plug

  require Ash.Query
  # `ref/1` builds a reference to an attribute named at runtime -- the host
  # chooses which attribute carries the hostname (FR-009), so it cannot be a
  # literal here.
  import Ash.Expr, only: [ref: 1]

  @refusal_reasons [:unregistered, :not_runnable, :lookup_failed]

  @impl true
  def init(opts) do
    %{
      registry: Keyword.fetch!(opts, :registry),
      host_attribute: Keyword.get(opts, :host_attribute, :owner_ref),
      on_refusal: Keyword.get(opts, :on_refusal)
    }
  end

  @impl true
  def call(conn, opts) do
    case resolve(conn.host, opts) do
      {:ok, sandbox} ->
        Plug.Conn.assign(conn, :sandbox, sandbox)

      {:error, reason} ->
        refuse(conn, reason, opts)
    end
  end

  @doc """
  Resolves a hostname to a sandbox, or refuses with a distinguishable reason.

  Public so the `check_origin` MFA and a host's own routing can share exactly
  this decision — two implementations of "is this hostname ours" is two chances
  to get the uncertain case wrong.
  """
  @spec resolve(String.t(), map()) ::
          {:ok, ExSandbox.Sandbox.t()} | {:error, :unregistered | :not_runnable | :lookup_failed}
  def resolve(hostname, %{registry: registry} = opts) when is_binary(hostname) do
    attribute = Map.get(opts, :host_attribute, :owner_ref)

    registry
    |> Ash.Query.filter(^ref(attribute) == ^hostname)
    |> Ash.Query.limit(1)
    |> Ash.read()
    |> case do
      {:ok, [record]} -> runnable(registry, record)
      {:ok, []} -> {:error, :unregistered}
      # Every error refuses. Authorizing on a lookup failure would let an
      # attacker who can induce them reach arbitrary sandboxes (006 R4).
      {:error, _reason} -> {:error, :lookup_failed}
    end
  rescue
    # Same rule, one layer out: a raise here is still uncertainty, and
    # uncertainty refuses.
    _error -> {:error, :lookup_failed}
  end

  def resolve(_hostname, _opts), do: {:error, :unregistered}

  @doc """
  The `check_origin` MFA target (`006` R6).

  Configure Phoenix with `check_origin: {AshSandbox.Plug, :origin_allowed?, [opts]}`.
  Never `false`: that satisfies the same requirement while opening cross-origin
  WebSocket hijacking against every tenant.
  """
  @spec origin_allowed?(String.t(), map()) :: boolean()
  def origin_allowed?(origin, opts) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) -> match?({:ok, _}, resolve(host, opts))
      _ -> false
    end
  end

  @doc "Every reason this plug can refuse for. Exposed for the host's telemetry."
  @spec refusal_reasons() :: [atom()]
  def refusal_reasons, do: @refusal_reasons

  defp runnable(registry, record) do
    sandbox = registry.to_sandbox(record)

    case AshSandbox.RunPolicy.check(AshSandbox.Resource.Info.run_policy(registry), sandbox) do
      :ok -> {:ok, sandbox}
      _refused -> {:error, :not_runnable}
    end
  end

  # Uniform: same status, same body, whatever the reason. A refusal that
  # distinguishes "no such hostname" from "exists but forbidden" is a hostname
  # oracle -- it tells an unauthenticated caller which tenants exist. The reason
  # rides along in `conn.private` for telemetry that never reaches the client.
  defp refuse(conn, reason, opts) do
    conn = Plug.Conn.put_private(conn, :ash_sandbox_refusal, reason)

    case Map.get(opts, :on_refusal) do
      {module, function, args} ->
        apply(module, function, [conn, reason | args])

      nil ->
        conn
        |> Plug.Conn.resp(404, "Not Found")
        |> Plug.Conn.halt()
    end
  end
end
