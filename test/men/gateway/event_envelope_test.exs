defmodule Men.Gateway.EventEnvelopeTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.EventEnvelope

  test "normalize 校验必填字段并输出规范结构" do
    input = %{
      type: "agent_result",
      source: "agent.agent_a",
      session_key: "s1",
      event_id: "e1",
      version: 3,
      ets_keys: ["agent.agent_a.data.result.task_1"],
      payload: %{signal: "ready"}
    }

    assert {:ok, envelope} = EventEnvelope.normalize(input)
    assert envelope.type == "agent_result"
    assert envelope.source == "agent.agent_a"
    assert envelope.session_key == "s1"
    assert envelope.event_id == "e1"
    assert envelope.version == 3
    assert envelope.ets_keys == ["agent.agent_a.data.result.task_1"]
    assert envelope.payload == %{signal: "ready"}
    assert is_integer(envelope.ts)
  end

  test "缺失 session_key/type/event_id 时 fail-closed" do
    assert {:error, {:invalid_field, :session_key}} =
             EventEnvelope.normalize(%{type: "x", source: "a", event_id: "e1", payload: %{}})

    assert {:error, {:invalid_field, :type}} =
             EventEnvelope.normalize(%{
               source: "a",
               session_key: "s1",
               event_id: "e1",
               payload: %{}
             })

    assert {:error, {:invalid_field, :event_id}} =
             EventEnvelope.normalize(%{type: "x", source: "a", session_key: "s1", payload: %{}})
  end

  test "payload 非 map 与非法 key 返回结构化错误" do
    assert {:error, {:invalid_field, :payload}} =
             EventEnvelope.normalize(%{
               type: "x",
               source: "a",
               session_key: "s1",
               event_id: "e1",
               payload: "bad"
             })

    assert {:error, {:invalid_field, :key}} =
             EventEnvelope.normalize(%{
               {:bad, :key} => "oops",
               type: "x",
               source: "a",
               session_key: "s1",
               event_id: "e1",
               payload: %{}
             })
  end

  test "任务状态事件契约归一化并补齐审计元数据" do
    input = %{
      type: "task_state_changed",
      source: "gateway.scheduler",
      session_key: "scheduler:default",
      event_id: "evt-task-1",
      payload: %{
        task_id: "task-1",
        from_state: "running",
        to_state: "failed",
        occurred_at: "2026-02-25T03:42:00Z",
        attempt: 2,
        reason_code: "TASK_TIMEOUT",
        reason_message: "start_to_close timeout",
        idempotent_hit: false
      }
    }

    assert {:ok, envelope} = EventEnvelope.normalize_task_state_event(input)
    assert envelope.type == "task_state_changed"
    assert envelope.payload.task_id == "task-1"
    assert envelope.payload.from_state == :running
    assert envelope.payload.to_state == :failed
    assert envelope.payload.occurred_at == "2026-02-25T03:42:00Z"
    assert envelope.payload.attempt == 2
    assert envelope.payload.reason_code == "TASK_TIMEOUT"
    assert envelope.payload.reason_message == "start_to_close timeout"
    assert envelope.payload.idempotent_hit == false
    assert envelope.meta.audit == true
    assert envelope.meta.replayable == true
    assert "task-1" in envelope.ets_keys
    assert "running" in envelope.ets_keys
    assert "failed" in envelope.ets_keys
  end

  test "任务状态事件遇到非法转移返回 TASK_INVALID_TRANSITION" do
    assert {:error,
            %{code: "TASK_INVALID_TRANSITION", from_state: :succeeded, to_state: :running}} =
             EventEnvelope.normalize_task_state_event(%{
               type: "task_state_changed",
               source: "gateway.scheduler",
               session_key: "scheduler:default",
               event_id: "evt-task-invalid-transition",
               payload: %{
                 task_id: "task-1",
                 from_state: "succeeded",
                 to_state: "running",
                 occurred_at: "2026-02-25T03:42:00Z"
               }
             })
  end

  test "任务状态事件要求 UTC ISO8601 occurred_at" do
    assert {:error, {:invalid_field, :occurred_at}} =
             EventEnvelope.normalize_task_state_event(%{
               type: "task_state_changed",
               source: "gateway.scheduler",
               session_key: "scheduler:default",
               event_id: "evt-task-time-invalid",
               payload: %{
                 task_id: "task-1",
                 from_state: "pending",
                 to_state: "ready",
                 occurred_at: "2026-02-25T11:42:00+08:00"
               }
             })
  end
end
