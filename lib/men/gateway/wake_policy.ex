defmodule Men.Gateway.WakePolicy do
  @moduledoc """
  Wake 判定策略：按策略源输出 must_wake/inbox_only 决策。
  """

  alias Men.Gateway.EventEnvelope

  @type decision :: %{
          wake: boolean(),
          inbox_only: boolean(),
          decision_reason: String.t(),
          policy_version: String.t()
        }

  @spec decide(EventEnvelope.t(), map()) ::
          {:ok, EventEnvelope.t(), decision()} | {:error, term()}
  def decide(%EventEnvelope{} = envelope, policy) when is_map(policy) do
    wake_policy = Map.get(policy, :wake) || Map.get(policy, "wake") || %{}

    must_wake =
      wake_policy
      |> Map.get("must_wake", Map.get(wake_policy, :must_wake, []))
      |> MapSet.new(&to_string/1)

    inbox_only =
      wake_policy
      |> Map.get("inbox_only", Map.get(wake_policy, :inbox_only, []))
      |> MapSet.new(&to_string/1)

    {wake, inbox, reason} =
      cond do
        MapSet.member?(must_wake, envelope.type) -> {true, false, "must_wake"}
        MapSet.member?(inbox_only, envelope.type) -> {false, true, "inbox_only"}
        true -> {false, true, "default_inbox_only"}
      end

    decision = %{
      wake: wake,
      inbox_only: inbox,
      decision_reason: reason,
      policy_version: policy_version(policy)
    }

    updated =
      envelope
      |> Map.put(:wake, wake)
      |> Map.put(:inbox_only, inbox)
      |> put_meta(:decision_reason, reason)
      |> put_meta(:policy_version, decision.policy_version)

    {:ok, updated, decision}
  end

  def decide(_, _), do: {:error, :invalid_event_envelope}

  defp put_meta(envelope, key, value) do
    meta = Map.put(envelope.meta || %{}, key, value)
    Map.put(envelope, :meta, meta)
  end

  defp policy_version(policy) do
    Map.get(policy, :policy_version) || Map.get(policy, "policy_version") || "unknown"
  end
end
