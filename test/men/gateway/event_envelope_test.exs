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
end
