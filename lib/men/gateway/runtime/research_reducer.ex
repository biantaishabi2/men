defmodule Men.Gateway.Runtime.ResearchReducer do
  @moduledoc """
  Research 图证据归并纯函数内核。
  """

  @type claim_id :: String.t()
  @type event :: map()

  @default_threshold 0.3

  @spec reduce(map(), [event()]) :: %{new_state: map(), diff: map(), explain: map()}
  def reduce(state, events) when is_map(state) and is_list(events) do
    threshold = Map.get(state, :blocking_threshold, @default_threshold)
    sorted_events = sort_events(events)

    baseline_state = normalize_state(state)

    {next_state, affected_claims} =
      Enum.reduce(sorted_events, {baseline_state, MapSet.new()}, fn event,
                                                                    {acc_state, acc_claims} ->
        claim_id = to_string(Map.get(event, :claim_id) || Map.get(event, "claim_id") || "")
        next = apply_event(acc_state, event)
        {next, MapSet.put(acc_claims, claim_id)}
      end)

    final_state = recompute_blocking(next_state, affected_claims, threshold)
    diff = build_diff(baseline_state, final_state, affected_claims)

    explain = %{
      event_order: Enum.map(sorted_events, &event_order_key/1),
      affected_claims: affected_claims |> MapSet.to_list() |> Enum.sort(),
      processed_events: length(sorted_events),
      blocking_threshold: threshold
    }

    %{new_state: final_state, diff: diff, explain: explain}
  end

  defp normalize_state(state) do
    claims =
      state
      |> Map.get(:claims, %{})
      |> Enum.into(%{}, fn {claim_id, claim_state} ->
        {
          to_string(claim_id),
          %{
            confidence: normalize_confidence(Map.get(claim_state, :confidence, 0.5)),
            blocking: Map.get(claim_state, :blocking, false)
          }
        }
      end)

    evidence_history =
      state
      |> Map.get(:evidence_history, %{})
      |> Enum.into(%{}, fn {claim_id, evidences} ->
        normalized =
          evidences
          |> List.wrap()
          |> Enum.map(&normalize_evidence/1)

        {to_string(claim_id), normalized}
      end)

    blocking =
      state
      |> Map.get(:blocking, [])
      |> normalize_blocking_ids()

    %{
      claims: claims,
      evidence_history: evidence_history,
      blocking: blocking,
      blocking_threshold: Map.get(state, :blocking_threshold, @default_threshold)
    }
  end

  defp normalize_blocking_ids(%MapSet{} = blocking) do
    blocking
    |> MapSet.to_list()
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp normalize_blocking_ids(blocking) do
    blocking
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp normalize_evidence(evidence) do
    %{
      evidence_id:
        to_string(Map.get(evidence, :evidence_id) || Map.get(evidence, "evidence_id") || ""),
      claim_id: to_string(Map.get(evidence, :claim_id) || Map.get(evidence, "claim_id") || ""),
      kind: Map.get(evidence, :kind) || Map.get(evidence, "kind") || :support,
      source_weight:
        normalize_weight(
          Map.get(evidence, :source_weight) || Map.get(evidence, "source_weight") || 1.0
        ),
      event_ts: Map.get(evidence, :event_ts) || Map.get(evidence, "event_ts") || 0,
      source_priority:
        Map.get(evidence, :source_priority) || Map.get(evidence, "source_priority") || 0
    }
  end

  defp sort_events(events) do
    Enum.sort_by(events, &event_order_key/1)
  end

  defp event_order_key(event) do
    [
      Map.get(event, :event_ts) || Map.get(event, "event_ts") || 0,
      Map.get(event, :source_priority) || Map.get(event, "source_priority") || 0,
      to_string(Map.get(event, :claim_id) || Map.get(event, "claim_id") || ""),
      to_string(Map.get(event, :evidence_id) || Map.get(event, "evidence_id") || ""),
      to_string(Map.get(event, :action) || Map.get(event, "action") || "")
    ]
  end

  defp apply_event(state, event) do
    action = Map.get(event, :action) || Map.get(event, "action")
    claim_id = to_string(Map.get(event, :claim_id) || Map.get(event, "claim_id") || "")

    case action do
      :support -> add_evidence(state, claim_id, event, :support)
      "support" -> add_evidence(state, claim_id, event, :support)
      :conflict -> add_evidence(state, claim_id, event, :conflict)
      "conflict" -> add_evidence(state, claim_id, event, :conflict)
      :retract -> retract_evidence(state, claim_id, event)
      "retract" -> retract_evidence(state, claim_id, event)
      _ -> state
    end
  end

  defp add_evidence(state, claim_id, event, kind) do
    evidence =
      normalize_evidence(
        event
        |> Map.put(:kind, kind)
        |> Map.put(:claim_id, claim_id)
      )

    claim = Map.get(state.claims, claim_id, %{confidence: 0.5, blocking: false})
    new_confidence = update_confidence(claim.confidence, kind, evidence.source_weight)

    updated_claims =
      Map.put(state.claims, claim_id, %{claim | confidence: new_confidence})

    updated_history =
      Map.update(state.evidence_history, claim_id, [evidence], fn existing ->
        existing ++ [evidence]
      end)

    %{state | claims: updated_claims, evidence_history: updated_history}
  end

  defp retract_evidence(state, claim_id, event) do
    target_evidence_id =
      to_string(Map.get(event, :evidence_id) || Map.get(event, "evidence_id") || "")

    history = Map.get(state.evidence_history, claim_id, [])

    remaining =
      Enum.reject(history, fn evidence ->
        evidence.evidence_id == target_evidence_id
      end)

    restored_confidence = replay_confidence(remaining)

    updated_claims =
      Map.put(state.claims, claim_id, %{
        confidence: restored_confidence,
        blocking: Map.get(state.claims[claim_id] || %{}, :blocking, false)
      })

    updated_history = Map.put(state.evidence_history, claim_id, remaining)
    %{state | claims: updated_claims, evidence_history: updated_history}
  end

  # 撤销后通过历史回放得到可重复状态，避免增量误差累积。
  defp replay_confidence(history) do
    history
    |> sort_events()
    |> Enum.reduce(0.5, fn evidence, acc ->
      update_confidence(acc, evidence.kind, evidence.source_weight)
    end)
  end

  defp update_confidence(current, :support, source_weight) do
    normalize_confidence(current + 0.15 * normalize_weight(source_weight))
  end

  defp update_confidence(current, :conflict, source_weight) do
    normalize_confidence(current - 0.20 * normalize_weight(source_weight))
  end

  defp normalize_weight(weight) when is_integer(weight), do: weight * 1.0
  defp normalize_weight(weight) when is_float(weight), do: weight
  defp normalize_weight(_), do: 1.0

  defp normalize_confidence(value) when is_integer(value),
    do: (value * 1.0) |> normalize_confidence()

  defp normalize_confidence(value) when is_float(value) do
    value
    |> min(1.0)
    |> max(0.0)
    |> Float.round(10)
  end

  defp normalize_confidence(_), do: 0.5

  # 仅对本轮受影响 claim 做 blocking 更新，避免全量扫描。
  defp recompute_blocking(state, affected_claims, threshold) do
    Enum.reduce(affected_claims, state, fn claim_id, acc ->
      confidence = get_in(acc, [:claims, claim_id, :confidence]) || 0.5
      blocked = confidence < threshold

      next_blocking =
        if blocked do
          MapSet.put(acc.blocking, claim_id)
        else
          MapSet.delete(acc.blocking, claim_id)
        end

      next_claim =
        Map.update(acc.claims, claim_id, %{confidence: confidence, blocking: blocked}, fn claim ->
          Map.put(claim, :blocking, blocked)
        end)

      %{acc | blocking: next_blocking, claims: next_claim}
    end)
  end

  defp build_diff(prev, curr, affected_claims) do
    changed_claims =
      affected_claims
      |> Enum.sort()
      |> Enum.reduce(%{}, fn claim_id, acc ->
        before_claim = Map.get(prev.claims, claim_id, %{confidence: 0.5, blocking: false})
        after_claim = Map.get(curr.claims, claim_id, %{confidence: 0.5, blocking: false})

        if before_claim != after_claim do
          Map.put(acc, claim_id, %{before: before_claim, after: after_claim})
        else
          acc
        end
      end)

    prev_blocking = prev.blocking
    curr_blocking = curr.blocking

    %{
      changed_claims: changed_claims,
      blocking_added:
        MapSet.difference(curr_blocking, prev_blocking) |> MapSet.to_list() |> Enum.sort(),
      blocking_removed:
        MapSet.difference(prev_blocking, curr_blocking) |> MapSet.to_list() |> Enum.sort()
    }
  end
end
