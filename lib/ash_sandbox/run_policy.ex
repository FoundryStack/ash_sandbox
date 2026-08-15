defmodule AshSandbox.RunPolicy do
  @moduledoc """
  The host answers "may this sandbox run?" (012 T026, FR-008).

  This behaviour replaces `003`'s citation of `002-FR-005a` (tenant lifecycle).
  A library cannot know what a tenant is, let alone that tenants have an
  `active` state — that citation was a dependency pointing the wrong way, and
  this is what it becomes.

  ## The library never asks why

  A refusal's reason is the **host's**, and is recorded verbatim. This library
  neither interprets it nor decides what counts as a good one. Axonn implements
  this against tenant `active` state; another host may always return `:ok`;
  a third may refuse on billing status. All three are equally valid here,
  which is the point.

  ## Called before provision and before start

  Both, not just provision. A sandbox provisioned while its owner was in good
  standing may be started later when it is not — checking only at provision
  time would let the second case through, which is the same shape as the
  suspension-reach problem `002` FR-005b describes.

      defmodule MyApp.SandboxRunPolicy do
        @behaviour AshSandbox.RunPolicy

        @impl true
        def may_run?(sandbox) do
          case MyApp.Accounts.status(sandbox.owner_ref) do
            :active -> :ok
            other -> {:error, {:owner_not_active, other}}
          end
        end
      end
  """

  @doc """
  Answers whether `sandbox` may run right now.

  `:ok` proceeds. `{:error, reason}` refuses, and `reason` is stored as given.
  """
  @callback may_run?(ExSandbox.Sandbox.t()) :: :ok | {:error, term()}

  @doc """
  Applies a run policy, treating "no policy configured" as permission.

  A host that supplies no policy has not thereby refused everything — it has
  declined to have an opinion, which for a library with no lifecycle concept of
  its own means proceed. Refusing by default would make `ex_sandbox` unusable
  out of the box for exactly the Story 1 consumer this split exists to serve.
  """
  @spec check(module() | nil, ExSandbox.Sandbox.t()) :: :ok | {:error, term()}
  def check(nil, _sandbox), do: :ok

  def check(policy, sandbox) when is_atom(policy) do
    policy.may_run?(sandbox)
  end
end
