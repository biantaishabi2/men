defmodule Men.Gateway.WakePolicyTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.EventEnvelope
  alias Men.Gateway.WakePolicy

  @policy %{
    wake: %{
      "must_wake" => ["agent_result", "agent_error", "policy_changed"],
      "inbox_only" => ["heartbeat", "tool_progress", "telemetry"]
    },
    policy_version: "p-1"
  }

  test "must_wake 事件" do
    assert {:ok, envelope} =
             EventEnvelope.normalize(%{
               type: "agent_result",
               source: "agent.agent_a",
               session_key: "s1",
               event_id: "e1",
               payload: %{}
             })

    assert {:ok, decided, decision} = WakePolicy.decide(envelope, @policy)
    assert decided.wake == true
    assert decided.inbox_only == false
    assert decision.decision_reason == "must_wake"
  end

  test "inbox_only 事件" do
    assert {:ok, envelope} =
             EventEnvelope.normalize(%{
               type: "tool_progress",
               source: "tool.t1",
               session_key: "s1",
               event_id: "e2",
               payload: %{}
             })

    assert {:ok, decided, decision} = WakePolicy.decide(envelope, @policy)
    assert decided.wake == false
    assert decided.inbox_only == true
    assert decision.decision_reason == "inbox_only"
  end

  test "默认分支" do
    assert {:ok, envelope} =
             EventEnvelope.normalize(%{
               type: "unknown_event",
               source: "system.gateway",
               session_key: "s1",
               event_id: "e3",
               payload: %{}
             })

    assert {:ok, decided, decision} = WakePolicy.decide(envelope, @policy)
    assert decided.wake == false
    assert decided.inbox_only == true
    assert decision.decision_reason == "default_inbox_only"
    assert decision.policy_version == "p-1"
  end
end
