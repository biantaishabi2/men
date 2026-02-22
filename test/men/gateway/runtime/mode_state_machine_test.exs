defmodule Men.Gateway.Runtime.ModeStateMachineTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.Runtime.ModeStateMachine

  test "场景1：research -> plan 满足置信度与稳定窗口后切换" do
    context = ModeStateMachine.initial_context()
    overrides = %{stable_window_ticks: 3, graph_stable_max: 0.05, enter_threshold: 0.75}

    snapshot = %{blocking_count: 0, key_claim_confidence: 0.82, graph_change_rate: 0.03}
    {mode_1, context, meta_1} = ModeStateMachine.decide(:research, snapshot, context, overrides)
    assert mode_1 == :research
    assert meta_1.reason == :graph_not_stable_yet

    snapshot = %{blocking_count: 0, key_claim_confidence: 0.82, graph_change_rate: 0.02}
    {mode_2, context, meta_2} = ModeStateMachine.decide(mode_1, snapshot, context, overrides)
    assert mode_2 == :research
    assert meta_2.reason == :graph_not_stable_yet

    snapshot = %{blocking_count: 0, key_claim_confidence: 0.82, graph_change_rate: 0.01}
    {mode_3, _context, meta_3} = ModeStateMachine.decide(mode_2, snapshot, context, overrides)

    assert mode_3 == :plan
    assert meta_3.transition? == true
    assert meta_3.reason == :confidence_and_stability_satisfied
  end

  test "场景2：plan -> execute 仅在 plan_selected 与 execute_compilable 同时满足时切换" do
    context = ModeStateMachine.initial_context()

    snapshot = %{plan_selected: true, execute_compilable: false}
    {mode_1, context, meta_1} = ModeStateMachine.decide(:plan, snapshot, context)
    assert mode_1 == :plan
    assert meta_1.reason == :plan_not_ready_for_execution

    snapshot = %{plan_selected: true, execute_compilable: true}
    {mode_2, _context, meta_2} = ModeStateMachine.decide(mode_1, snapshot, context)

    assert mode_2 == :execute
    assert meta_2.reason == :plan_ready_for_execution
  end

  test "场景3：execute -> research 按优先级命中 premise_invalidated" do
    context = ModeStateMachine.initial_context()

    snapshot = %{
      premise_invalidated: true,
      external_mutation: true,
      uncovered_critical_paths: 4,
      total_critical_paths: 10
    }

    {mode, _context, meta} =
      ModeStateMachine.decide(:execute, snapshot, context, %{cooldown_ticks: 3})

    assert mode == :research
    assert meta.reason == :premise_invalidated
    assert meta.priority == :high
  end

  test "边界场景：置信度在 0.61~0.74 波动且未满足进入阈值时保持 research" do
    context = ModeStateMachine.initial_context()

    {mode, context, _meta} =
      ModeStateMachine.decide(
        :research,
        %{blocking_count: 0, key_claim_confidence: 0.61, graph_change_rate: 0.01},
        context,
        %{stable_window_ticks: 1}
      )

    assert mode == :research

    {mode, _context, meta} =
      ModeStateMachine.decide(
        mode,
        %{blocking_count: 0, key_claim_confidence: 0.74, graph_change_rate: 0.01},
        context,
        %{stable_window_ticks: 1}
      )

    assert mode == :research
    assert meta.reason == :confidence_below_enter_threshold
  end

  test "cooldown 内外部突变回退被抑制，前提失效可强制突破" do
    context = %{
      ModeStateMachine.initial_context()
      | cooldown_remaining: 2
    }

    {mode_1, context, meta_1} =
      ModeStateMachine.decide(
        :execute,
        %{external_mutation: true},
        context,
        %{cooldown_ticks: 3}
      )

    assert mode_1 == :execute
    assert meta_1.reason == :cooldown_blocked

    {mode_2, _context, meta_2} =
      ModeStateMachine.decide(
        :execute,
        %{premise_invalidated: true},
        context,
        %{cooldown_ticks: 3}
      )

    assert mode_2 == :research
    assert meta_2.reason == :premise_invalidated
  end
end
