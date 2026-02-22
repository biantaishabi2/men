defmodule Men.Gateway.Runtime.FrameSnapshotBuilderTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.Runtime.FrameSnapshotBuilder
  alias Men.Gateway.Runtime.FrameSnapshotBuilder.FrameSnapshot

  test "大量历史输入时输出按阈值裁剪且保留可追溯引用" do
    runtime_state = %{
      goal: "完成 DAG 排期",
      policy: %{mode: :action, strict: true},
      current_focus: %{
        text: String.duplicate("f", 260),
        refs: ["ref-1", "ref-2", "ref-3", "ref-4"]
      },
      next_candidates: Enum.map(1..8, &%{id: "c#{&1}", title: "candidate-#{&1}"}),
      constraints: [
        %{text: "active-1", active: true},
        %{text: "active-2", active: true},
        %{text: "inactive", active: false},
        %{text: "active-3", active: true},
        %{text: "active-4", active: true}
      ],
      recommendations: [
        %{text: String.duplicate("r", 220), priority: :high, source: :solver},
        %{text: "keep me", priority: :normal},
        %{text: "drop me", priority: :low}
      ],
      event_ids: ["e-1", "e-2", "e-3"],
      node_ids: ["n-1", "n-2"]
    }

    snapshot = FrameSnapshotBuilder.build(runtime_state, snapshot_type: :action_snapshot)

    assert %FrameSnapshot{} = snapshot
    assert snapshot.snapshot_type == :action_snapshot
    assert snapshot.goal == "完成 DAG 排期"
    assert snapshot.policy == %{mode: :action, strict: true}
    assert String.length(snapshot.current_focus.text) == 200
    assert length(snapshot.current_focus.refs) == 3
    assert length(snapshot.next_candidates) == 5
    assert Enum.map(snapshot.constraints, & &1.text) == ["active-1", "active-2", "active-3"]
    assert length(snapshot.recommendations) == 2
    assert String.length(hd(snapshot.recommendations).text) == 150
    assert snapshot.state_ref == %{event_id: "e-1", node_id: "n-1"}
    assert is_integer(snapshot.generated_at)
    assert snapshot.debug_info == nil
  end

  test "idle 场景仅保留最小控制快照" do
    runtime_state = %{
      goal: "等待外部事件",
      constraints: [%{text: "只读", active: true}, %{text: "二级约束", active: true}],
      next_candidates: [%{id: "c1", title: "run"}],
      recommendations: [%{text: "continue idle", priority: :normal}]
    }

    snapshot = FrameSnapshotBuilder.build(runtime_state, snapshot_type: :idle_snapshot)

    assert snapshot.snapshot_type == :idle_snapshot
    assert snapshot.next_candidates == []
    assert snapshot.constraints == [%{text: "只读", active: true}]
    assert snapshot.recommendations == [%{text: "continue idle", priority: :normal}]
  end

  test "可选字段缺失时稳定降级为默认值" do
    snapshot = FrameSnapshotBuilder.build(%{goal: "g"}, snapshot_type: :action_snapshot)

    assert snapshot.goal == "g"
    assert snapshot.policy == nil
    assert snapshot.current_focus == nil
    assert snapshot.next_candidates == []
    assert snapshot.constraints == []
    assert snapshot.recommendations == []
    assert snapshot.state_ref == %{}
    assert snapshot.debug_info == nil
  end

  test "debug 开关控制最小 state_ref 与完整 debug_info" do
    runtime_state = %{
      goal: "g",
      event_ids: ["e-1", "e-2", "e-3"],
      node_ids: ["n-1", "n-2"]
    }

    normal = FrameSnapshotBuilder.build(runtime_state, debug: false)
    debug = FrameSnapshotBuilder.build(runtime_state, debug: true)

    assert normal.state_ref == %{event_id: "e-1", node_id: "n-1"}
    assert normal.debug_info == nil

    assert debug.state_ref == %{event_id: "e-1", node_id: "n-1"}
    assert debug.debug_info == %{event_ids: ["e-1", "e-2", "e-3"], node_ids: ["n-1", "n-2"]}
  end

  test "mixed 类型引用时 state_ref 与 debug_info 使用一致过滤规则" do
    runtime_state = %{
      event_ids: [123, nil, "e-1", "e-2"],
      node_ids: [%{id: "n-x"}, "n-1", 99]
    }

    snapshot = FrameSnapshotBuilder.build(runtime_state, debug: true)

    assert snapshot.state_ref == %{event_id: "e-1", node_id: "n-1"}
    assert snapshot.debug_info == %{event_ids: ["e-1", "e-2"], node_ids: ["n-1"]}
  end
end
