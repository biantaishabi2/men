defmodule Men.Gateway.Runtime.ResearchReducerTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.Runtime.ResearchReducer

  test "冲突证据同时到达时按稳定顺序处理且结果确定" do
    initial = %{}

    events = [
      %{
        event_ts: 100,
        source_priority: 2,
        claim_id: "c1",
        evidence_id: "e-conflict",
        action: :conflict,
        source_weight: 0.5
      },
      %{
        event_ts: 100,
        source_priority: 1,
        claim_id: "c1",
        evidence_id: "e-support",
        action: :support,
        source_weight: 1.0
      }
    ]

    result1 = ResearchReducer.reduce(initial, events)
    result2 = ResearchReducer.reduce(initial, events)

    assert result1.new_state.claims["c1"].confidence == 0.55
    assert result1.new_state.claims["c1"].blocking == false

    assert result1.explain.event_order == [
             [100, 1, "c1", "e-support", "support"],
             [100, 2, "c1", "e-conflict", "conflict"]
           ]

    assert result1 == result2
  end

  test "撤销事件通过 evidence_history 回放恢复到添加前状态" do
    initial = %{}

    add_events = [
      %{
        event_ts: 1,
        source_priority: 1,
        claim_id: "c1",
        evidence_id: "e1",
        action: :support,
        source_weight: 1.0
      },
      %{
        event_ts: 2,
        source_priority: 1,
        claim_id: "c1",
        evidence_id: "e2",
        action: :conflict,
        source_weight: 0.5
      }
    ]

    added = ResearchReducer.reduce(initial, add_events).new_state

    retract_events = [
      %{event_ts: 3, source_priority: 1, claim_id: "c1", evidence_id: "e2", action: :retract}
    ]

    result = ResearchReducer.reduce(added, retract_events)

    assert result.new_state.claims["c1"].confidence == 0.65
    assert Enum.map(result.new_state.evidence_history["c1"], & &1.evidence_id) == ["e1"]
  end

  test "blocking 阈值重算只更新受影响 claim" do
    initial = %{
      claims: %{
        "c1" => %{confidence: 0.35, blocking: false},
        "c2" => %{confidence: 0.2, blocking: true}
      },
      blocking: ["c2"]
    }

    events = [
      %{
        event_ts: 10,
        source_priority: 1,
        claim_id: "c1",
        evidence_id: "e3",
        action: :conflict,
        source_weight: 1.0
      }
    ]

    result = ResearchReducer.reduce(initial, events)

    assert result.new_state.claims["c1"].confidence == 0.15
    assert result.new_state.claims["c1"].blocking == true
    assert result.new_state.claims["c2"].blocking == true
    assert result.diff.blocking_added == ["c1"]
    assert result.diff.blocking_removed == []
    assert result.explain.affected_claims == ["c1"]
  end
end
