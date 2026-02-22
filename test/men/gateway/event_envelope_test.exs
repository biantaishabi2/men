defmodule Men.Gateway.EventEnvelopeTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.EventEnvelope

  test "normalize 支持 atom/string key 并补全默认值" do
    input = %{
      "type" => "agent_result",
      :source => :agent_1,
      "target" => "control",
      :event_id => "E1",
      "version" => 10,
      :payload => %{result: "ok"}
    }

    assert {:ok, envelope} = EventEnvelope.normalize(input)
    assert envelope.type == "agent_result"
    assert envelope.source == "agent_1"
    assert envelope.target == "control"
    assert envelope.event_id == "E1"
    assert envelope.version == 10
    assert envelope.wake == nil
    assert envelope.inbox_only == nil
    assert envelope.force_wake == false
    assert envelope.ets_keys == ["agent_result", "agent_1", "control"]
    assert envelope.payload == %{result: "ok"}
    assert is_integer(envelope.ts)
    assert envelope.meta == %{}
  end

  test "normalize 无效字段返回错误" do
    assert {:error, {:invalid_field, :type}} =
             EventEnvelope.normalize(%{event_id: "E2", version: 1})

    assert {:error, {:invalid_field, :event_id}} =
             EventEnvelope.normalize(%{type: "heartbeat", event_id: "", version: 1})

    assert {:error, {:invalid_field, :version}} =
             EventEnvelope.normalize(%{type: "heartbeat", event_id: "E2", version: -1})

    assert {:error, {:invalid_field, :meta}} =
             EventEnvelope.normalize(%{type: "heartbeat", event_id: "E2", version: 1, meta: "bad"})
  end

  test "from_map 支持 struct 输入并保持规范化" do
    assert {:ok, original} =
             EventEnvelope.normalize(%{
               type: "heartbeat",
               event_id: "E3",
               version: 1,
               source: "worker",
               target: "control",
               wake: false,
               inbox_only: true,
               ets_keys: ["scope", "a"]
             })

    assert {:ok, normalized} = EventEnvelope.normalize(original)
    assert normalized == original
  end
end
