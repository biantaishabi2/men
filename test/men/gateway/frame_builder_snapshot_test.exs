defmodule Men.Gateway.FrameBuilderSnapshotTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.FrameBuilder

  test "按 sections 注入仅输出请求字段" do
    runtime_state = %{
      goal: "goal-a",
      current_focus: %{text: "focus", refs: ["r1"]},
      constraints: [%{text: "c1", active: true}],
      recommendations: [%{text: "rec", priority: :high}]
    }

    frame =
      FrameBuilder.build(runtime_state,
        snapshot_type: :idle_snapshot,
        sections: [:goal, :current_focus, :constraints]
      )

    assert frame.snapshot_type == :idle_snapshot
    assert Map.keys(frame.sections) |> Enum.sort() == [:constraints, :current_focus, :goal]
    assert frame.sections.goal == "goal-a"
    assert frame.sections.current_focus == %{text: "focus", refs: ["r1"]}
    assert frame.sections.constraints == [%{text: "c1", active: true}]
  end

  test "recommendations 在 action 场景合并到 next_candidates 头部" do
    runtime_state = %{
      next_candidates: [
        %{id: "c1", title: "candidate-1"},
        %{id: "c2", title: "candidate-2"}
      ],
      recommendations: [
        %{text: "do first", priority: :high},
        %{text: "normal", priority: :normal}
      ]
    }

    frame = FrameBuilder.build(runtime_state, snapshot_type: :action_snapshot)

    assert [%{source: :recommendation, title: "do first"} | _] = frame.sections.next_candidates
    assert frame.sections.recommendations == []
  end

  test "recommendations 在 handoff 场景保留并标注来源" do
    runtime_state = %{
      recommendations: [
        %{text: "handoff-1", priority: :high},
        %{text: "handoff-2", priority: :normal}
      ]
    }

    frame =
      FrameBuilder.build(runtime_state,
        snapshot_type: :handoff_snapshot,
        sections: [:recommendations]
      )

    assert frame.sections.recommendations == [
             %{
               text: "handoff-1",
               priority: :high,
               source: :recommender,
               origin: :recommendations
             },
             %{
               text: "handoff-2",
               priority: :normal,
               source: :recommender,
               origin: :recommendations
             }
           ]
  end

  test "缺失字段时 sections 默认值稳定" do
    frame =
      FrameBuilder.build(%{},
        snapshot_type: :action_snapshot,
        sections: [:goal, :next_candidates, :constraints, :recommendations, :state_ref]
      )

    assert frame.sections.goal == nil
    assert frame.sections.next_candidates == []
    assert frame.sections.constraints == []
    assert frame.sections.recommendations == []
    assert frame.sections.state_ref == %{}
  end

  test "idle 场景 recommendations 独立输出" do
    runtime_state = %{
      recommendations: [%{text: "standby", priority: :normal}],
      next_candidates: [%{id: "n1", title: "run"}]
    }

    frame = FrameBuilder.build(runtime_state, snapshot_type: :idle_snapshot)

    assert frame.sections.recommendations == [%{text: "standby", priority: :normal}]
    assert frame.sections.next_candidates == []
  end

  test "agent loop frame 默认预算与裁剪生效" do
    frame =
      FrameBuilder.build_agent_loop_frame(%{
        inbox: Enum.map(1..30, &%{id: &1}),
        pending_actions: [%{action_id: "a1"}],
        recent_receipts: [%{receipt_id: "r1"}]
      })

    assert frame.budget.tokens == 16_000
    assert frame.budget.messages == 20
    assert length(frame.inbox) == 20
    assert frame.pending_actions == [%{action_id: "a1"}]
    assert frame.recent_receipts == [%{receipt_id: "r1"}]
  end
end
