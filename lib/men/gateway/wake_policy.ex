defmodule Men.Gateway.WakePolicy do
  @moduledoc """
  Wake/Inbox 决策策略：默认安全优先，并支持运行时覆盖。
  """

  alias Men.Gateway.EventEnvelope

  @default_type_policies %{
    "agent_result" => %{wake: true, inbox_only: false},
    "agent_error" => %{wake: true, inbox_only: false},
    "policy_changed" => %{wake: true, inbox_only: false},
    "heartbeat" => %{wake: false, inbox_only: true},
    "tool_progress" => %{wake: false, inbox_only: true},
    "telemetry" => %{wake: false, inbox_only: true}
  }

  @default_policy %{wake: false, inbox_only: true}

  @type decision :: %{
          wake: boolean(),
          inbox_only: boolean(),
          strict_inbox_priority: boolean(),
          force_wake: boolean()
        }

  @spec decide(EventEnvelope.t(), keyword() | map()) ::
          {:ok, EventEnvelope.t(), decision()} | {:error, term()}
  def decide(envelope, overrides \\ %{})

  def decide(%EventEnvelope{} = envelope, overrides) do
    overrides_map = normalize_overrides(overrides)
    strict_inbox_priority = Map.get(overrides_map, :strict_inbox_priority, true)

    type_defaults =
      overrides_map
      |> Map.get(:type_defaults, %{})
      |> normalize_type_defaults()
      |> then(&Map.merge(@default_type_policies, &1))

    event_default = Map.get(type_defaults, envelope.type, @default_policy)

    resolved_wake =
      pick_value(
        envelope.wake,
        Map.get(overrides_map, :wake),
        Map.get(event_default, :wake, false)
      )

    resolved_inbox_only =
      pick_value(
        envelope.inbox_only,
        Map.get(overrides_map, :inbox_only),
        Map.get(event_default, :inbox_only, true)
      )

    {final_wake, final_inbox_only} =
      resolve_conflict(
        resolved_wake,
        resolved_inbox_only,
        strict_inbox_priority,
        envelope.force_wake
      )

    decision = %{
      wake: final_wake,
      inbox_only: final_inbox_only,
      strict_inbox_priority: strict_inbox_priority,
      force_wake: envelope.force_wake
    }

    {:ok, %EventEnvelope{envelope | wake: final_wake, inbox_only: final_inbox_only}, decision}
  end

  def decide(_event, _overrides), do: {:error, :invalid_event_envelope}

  defp pick_value(event_explicit, runtime_override, fallback) do
    cond do
      is_boolean(event_explicit) -> event_explicit
      is_boolean(runtime_override) -> runtime_override
      true -> fallback
    end
  end

  # 冲突时默认 inbox_only 优先；仅在 strict=false 且 force_wake=true 时放行唤醒。
  defp resolve_conflict(true, true, true, _force_wake), do: {false, true}
  defp resolve_conflict(true, true, false, true), do: {true, false}
  defp resolve_conflict(true, true, false, _force_wake), do: {false, true}
  defp resolve_conflict(wake, inbox_only, _strict, _force_wake), do: {wake, inbox_only}

  defp normalize_overrides(overrides) when is_list(overrides), do: Map.new(overrides)
  defp normalize_overrides(overrides) when is_map(overrides), do: overrides
  defp normalize_overrides(_), do: %{}

  defp normalize_type_defaults(%{} = type_defaults) do
    Enum.reduce(type_defaults, %{}, fn {key, value}, acc ->
      type_key =
        case key do
          k when is_atom(k) -> Atom.to_string(k)
          k when is_binary(k) -> k
          _ -> nil
        end

      normalized_value =
        case value do
          %{wake: wake, inbox_only: inbox_only}
          when is_boolean(wake) and is_boolean(inbox_only) ->
            %{wake: wake, inbox_only: inbox_only}

          _ ->
            nil
        end

      if is_nil(type_key) or is_nil(normalized_value),
        do: acc,
        else: Map.put(acc, type_key, normalized_value)
    end)
  end

  defp normalize_type_defaults(_), do: %{}
end
