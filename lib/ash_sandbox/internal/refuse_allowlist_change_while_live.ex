defmodule AshSandbox.Internal.RefuseAllowlistChangeWhileLive do
  @moduledoc """
  Refuses a change to an `Environment`'s `network_allowlist` while that
  environment has a live sandbox (029 T018 ruling, `FR-011`).

  ## Why a refusal and not a silent success

  A sandbox is policed by rules its mechanism installs **at launch**, from the
  allowlist as it read then; nothing re-reads it afterwards. So an accepted
  narrowing would be persisted while every already-running sandbox kept the
  wider rules — a control that reports success and changes nothing. Widening is
  the mirror: the destination is recorded and unreachable until the sandbox is
  replaced.

  ⚠️ **Re-policing the running sandbox is the better product answer and was
  deliberately not built here.** Rewriting a live ruleset is its own correctness
  problem — a narrowing must never be observable as a half-applied ruleset — and
  `029` has not yet demonstrated that the rules it installs *at launch* hold at
  all: the observation halves of its enforcement tasks need a Linux network
  namespace and have never run. Building live re-policing on top of enforcement
  whose boundary is unverified is the same inversion the spec exists to catch.

  So the update either takes effect at the next launch, or it is refused in a
  sentence naming why.

  ## The registry resource arrives as data

  The host names its own registry binding at its own `use
  AshSandbox.EnvironmentTemplate` call site (`012-FR-009`); this library
  compiles knowing no host module. That is the same rule
  `AshSandbox.Internal.CopyOwnerRefFromProject` follows for the `Project`
  binding, reached differently only because there is no relationship to read it
  off: `environment_ref` is an opaque **string** on the registry row while
  `Environment.id` is a uuid, so a `has_one` would emit a `uuid = text`
  comparison the data layer refuses.

  ## What "live" means

  `AshSandbox.RegistryTemplate.live_states/0`, enumerated there rather than
  written here as "not stopped" — see that function for why.
  """
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def init(opts) do
    case opts[:registry_resource] do
      module when is_atom(module) and not is_nil(module) ->
        {:ok, opts}

      other ->
        {:error,
         "registry_resource must be the host's registry resource module, got: #{inspect(other)}"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    # ⚠️ Only when the value actually differs. Ash drops an attribute from the
    # changeset when the cast value equals the stored one, so resubmitting the
    # same allowlist — which is what a form that posts every field does — is not
    # a change and has nothing to enforce. Refusing it would make the whole
    # record uneditable while a sandbox runs, which is not what was ruled.
    if Ash.Changeset.changing_attribute?(changeset, :network_allowlist) do
      refuse_if_live(changeset, Keyword.fetch!(opts, :registry_resource))
    else
      :ok
    end
  end

  defp refuse_if_live(changeset, registry_resource) do
    environment_ref = to_string(changeset.data.id)
    live_states = AshSandbox.RegistryTemplate.live_states()

    # `authorize?: false`: this is not an authorization decision about the
    # registry, it is the environment's own write path establishing a fact about
    # a row the caller may well not be permitted to read. The environment update
    # itself is still policed by `Environment`'s own policies.
    registry_resource
    |> Ash.Query.filter(environment_ref == ^environment_ref and state in ^live_states)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, []} ->
        :ok

      {:ok, [live | _]} ->
        refusal(
          "cannot be changed while this environment's sandbox is live " <>
            "(sandbox #{live.id} is #{inspect(live.state)}). Its network rules were installed " <>
            "when it launched and are never re-read, so this change would be recorded and not " <>
            "enforced. Stop the sandbox, change the allowlist, then launch again."
        )

      # ⚠️ Refused, not permitted. A read that failed has not established that
      # the environment has no live sandbox — it has established that the
      # question could not be answered, and treating those as the same thing is
      # how an operator narrows an allowlist that stays wide.
      {:error, reason} ->
        refusal(
          "cannot be changed: whether this environment has a live sandbox could not be " <>
            "determined (#{inspect(reason)}). Refusing rather than assuming there is none."
        )
    end
  end

  defp refusal(message), do: {:error, field: :network_allowlist, message: message}
end
