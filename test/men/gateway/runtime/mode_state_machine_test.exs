defmodule Men.Gateway.Runtime.ModeStateMachineTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.Runtime.ModeStateMachine

  test "research 场景：证据稳定且 execute 可编译时给出 execute 建议（默认不强制切换）" do
    context = ModeStateMachine.initial_context()
    overrides = %{stable_window_ticks: 2, graph_stable_max: 0.05, enter_threshold: 0.75}

    {mode_1, context, meta_1} =
      ModeStateMachine.decide(
        :research,
        %{
          blocking_count: 0,
          key_claim_confidence: 0.9,
          graph_change_rate: 0.03,
          execute_compilable: true
        },
        context,
        overrides
      )

    assert mode_1 == :research
    assert meta_1.recommended_mode == :hold

    {mode_2, _context, meta_2} =
      ModeStateMachine.decide(
        :research,
        %{
          blocking_count: 0,
          key_claim_confidence: 0.9,
          graph_change_rate: 0.01,
          execute_compilable: true
        },
        context,
        overrides
      )

    assert mode_2 == :research
    assert meta_2.transition? == false
    assert meta_2.recommended_mode == :execute
    assert meta_2.reason == :evidence_and_compile_ready
  end

  test "research 场景：未达阈值时给出 hold 建议" do
    context = ModeStateMachine.initial_context()

    {mode, _context, meta} =
      ModeStateMachine.decide(
        :research,
        %{
          blocking_count: 0,
          key_claim_confidence: 0.6,
          graph_change_rate: 0.01,
          execute_compilable: true
        },
        context
      )

    assert mode == :research
    assert meta.recommended_mode == :hold
    assert meta.reason == :confidence_below_enter_threshold
  end

  test "execute 场景：前提失效时建议回退 research" do
    context = ModeStateMachine.initial_context()

    {mode, _context, meta} =
      ModeStateMachine.decide(:execute, %{premise_invalidated: true}, context)

    assert mode == :execute
    assert meta.recommended_mode == :research
    assert meta.reason == :premise_invalidated
    assert meta.priority == :high
  end

  test "execute 场景：稳定时建议 hold" do
    context = ModeStateMachine.initial_context()

    {mode, _context, meta} = ModeStateMachine.decide(:execute, %{}, context)

    assert mode == :execute
    assert meta.recommended_mode == :hold
    assert meta.reason == :execute_stable
  end

  test "apply_mode?=true 时允许应用建议为实际迁移" do
    context = ModeStateMachine.initial_context()

    {mode_1, context, _meta_1} =
      ModeStateMachine.decide(
        :research,
        %{
          blocking_count: 0,
          key_claim_confidence: 0.9,
          graph_change_rate: 0.02,
          execute_compilable: true
        },
        context,
        %{stable_window_ticks: 2, apply_mode?: true}
      )

    assert mode_1 == :research

    {mode_2, _context, meta_2} =
      ModeStateMachine.decide(
        mode_1,
        %{
          blocking_count: 0,
          key_claim_confidence: 0.9,
          graph_change_rate: 0.01,
          execute_compilable: true
        },
        context,
        %{stable_window_ticks: 2, apply_mode?: true}
      )

    assert mode_2 == :execute
    assert meta_2.transition? == true
    assert meta_2.to_mode == :execute
    assert meta_2.recommended_mode == :execute
  end
end
