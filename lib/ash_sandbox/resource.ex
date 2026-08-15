defmodule AshSandbox.Resource do
  @moduledoc """
  A DSL extension for declaring a sandbox's limits, idle timeout, and mechanism
  (012 T027).

      defmodule MyApp.SandboxRegistry do
        use AshSandbox.RegistryTemplate,
          data_layer: Ash.DataLayer.Ets,
          domain: MyApp.Sandboxes,
          table: "sandboxes"

        sandbox do
          mechanism ExSandbox.Mechanism.Beam
          cpu_limit 500
          memory_limit_mb 256
          disk_quota_mb 1024
          idle_timeout_seconds 900
          run_policy MyApp.SandboxRunPolicy
        end
      end

  `AshSandbox.RegistryTemplate` wires this extension in for you — a Spark
  extension has to reach `use Ash.Resource` via `extensions:`, so it cannot be
  `use`d on a line of its own after the template.

  ## ⚠️ These are declared limits, not enforced limits

  Nothing in this module enforces anything. Nothing **inside the BEAM** can:
  `005` established that the enforcement boundary is the operating system, and
  a VM cannot cap its own OS process's memory.

  The division is:

    * `AshSandbox.Resource` (here) — **declares** intent
    * `ExSandbox.Hardening` — **enforces** it at the OS level
    * `ExSandbox.Capability` — reports when the host **cannot** enforce it
    * `ExSandbox.Conformance` — proves enforcement by breaching the cap

  Where the host cannot enforce — macOS lacks default-deny confinement, and
  `taskpolicy -m` is silently lost across an intervening exec (`005` R9/R9b) —
  the capability is reported unavailable (`FR-016`) and the mechanism refuses to
  start sandboxes rather than starting them unconfined.

  Reading a `memory_limit_mb 256` here as "this sandbox is capped at 256 MB" is
  precisely the mistake `FR-012a` exists to prevent. It says what was asked for.
  """

  @sandbox %Spark.Dsl.Section{
    name: :sandbox,
    describe: """
    Declares how a sandbox for this resource should be run.

    Every option here is a *declaration*. See the module documentation for why
    that is not the same as an enforced limit.
    """,
    examples: [
      """
      sandbox do
        mechanism ExSandbox.Mechanism.Beam
        memory_limit_mb 256
        idle_timeout_seconds 900
      end
      """
    ],
    schema: [
      mechanism: [
        type: {:behaviour, ExSandbox.Mechanism},
        doc: "The module implementing `ExSandbox.Mechanism` that runs these sandboxes."
      ],
      run_policy: [
        type: {:behaviour, AshSandbox.RunPolicy},
        doc: """
        A host-supplied module answering "may this sandbox run?". Omitting it
        means the host has declined to have an opinion, which is treated as
        permission -- see `AshSandbox.RunPolicy.check/2`.
        """
      ],
      cpu_limit: [
        type: :non_neg_integer,
        doc: "Requested CPU in millicores (`003-FR-004`)."
      ],
      memory_limit_mb: [
        type: :non_neg_integer,
        doc: "Requested memory ceiling in megabytes."
      ],
      disk_quota_mb: [
        type: :non_neg_integer,
        doc: "Requested disk ceiling in megabytes."
      ],
      idle_timeout_seconds: [
        type: :non_neg_integer,
        doc: """
        How long a running sandbox may sit idle before the host may reclaim it.
        Reclamation is the host's action; this only records the intent.
        """
      ]
    ]
  }

  use Spark.Dsl.Extension, sections: [@sandbox]
end

defmodule AshSandbox.Resource.Info do
  @moduledoc """
  Reads back what `AshSandbox.Resource` declared.

  Every function here returns what the resource **asked for**. None of it is
  evidence that a limit is in force — see `AshSandbox.Resource`.
  """

  @doc "The mechanism module declared for this resource, if any."
  @spec mechanism(Spark.Dsl.t() | module()) :: module() | nil
  def mechanism(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:sandbox], :mechanism, nil)
  end

  @doc "The host-supplied run policy, if any."
  @spec run_policy(Spark.Dsl.t() | module()) :: module() | nil
  def run_policy(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:sandbox], :run_policy, nil)
  end

  @doc "The declared idle timeout in seconds, if any."
  @spec idle_timeout_seconds(Spark.Dsl.t() | module()) :: non_neg_integer() | nil
  def idle_timeout_seconds(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:sandbox], :idle_timeout_seconds, nil)
  end

  @doc """
  The declared limits, as the map `ExSandbox.Hardening` takes.

  Named `declared_limits` rather than `limits` on purpose: at the call site,
  `limits(resource)` reads like a fact about the running sandbox.
  """
  @spec declared_limits(Spark.Dsl.t() | module()) :: ExSandbox.Hardening.limits()
  def declared_limits(resource) do
    [
      cpu_millicores: get(resource, :cpu_limit),
      memory_mb: get(resource, :memory_limit_mb),
      disk_mb: get(resource, :disk_quota_mb)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp get(resource, key), do: Spark.Dsl.Extension.get_opt(resource, [:sandbox], key, nil)
end
