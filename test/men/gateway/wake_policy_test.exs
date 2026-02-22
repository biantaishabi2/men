defmodule Men.Gateway.WakePolicyTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.EventEnvelope
  alias Men.Gateway.WakePolicy

  test "agent_result 默认触发 wake 且非 inbox_only" do
    assert {:ok, envelope} =
             EventEnvelope.normalize(%{
               type: "agent_result",
               event_id: "E1",
               version: 10,
               source: "agent",
               target: "control"
             })

    assert {:ok, decided, decision} = WakePolicy.decide(envelope, %{})
    assert decided.wake == true
    assert decided.inbox_only == false
    assert decision.strict_inbox_priority == true
  end

  test "heartbeat 默认仅 inbox" do
    assert {:ok, envelope} =
             EventEnvelope.normalize(%{
               type: "heartbeat",
               event_id: "E2",
               version: 1,
               source: "agent",
               target: "control"
             })

    assert {:ok, decided, _decision} = WakePolicy.decide(envelope, %{})
    assert decided.wake == false
    assert decided.inbox_only == true
  end

  test "strict_inbox_priority=true 时 force_wake 不生效" do
    assert {:ok, envelope} =
             EventEnvelope.normalize(%{
               type: "agent_result",
               event_id: "E3",
               version: 1,
               source: "agent",
               target: "control",
               wake: true,
               inbox_only: true,
               force_wake: true
             })

    assert {:ok, decided, decision} = WakePolicy.decide(envelope, %{strict_inbox_priority: true})
    assert decided.wake == false
    assert decided.inbox_only == true
    assert decision.force_wake == true
  end

  test "strict_inbox_priority=false 且 force_wake=true 时允许唤醒" do
    assert {:ok, envelope} =
             EventEnvelope.normalize(%{
               type: "heartbeat",
               event_id: "E4",
               version: 1,
               source: "agent",
               target: "control",
               wake: true,
               inbox_only: true,
               force_wake: true
             })

    assert {:ok, decided, _decision} =
             WakePolicy.decide(envelope, %{strict_inbox_priority: false})

    assert decided.wake == true
    assert decided.inbox_only == false
  end
end
