defmodule Men.Gateway.EventBusTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.EventBus

  test "publish_schedule_trigger 冻结标准字段并透传 metadata 扩展" do
    topic = "event_bus_test_#{System.unique_integer([:positive, :monotonic])}"
    :ok = EventBus.subscribe(topic)

    :ok =
      EventBus.publish_schedule_trigger(topic, %{
        schedule_id: "schedule-1",
        fire_time: ~U[2026-02-25 12:00:00Z],
        idempotency_key: "schedule-1:2026-02-25T12:00:00Z",
        schedule_type: :at,
        triggered_at: "2026-02-25T12:00:01Z",
        metadata: %{trace_id: "trace-1"},
        tenant: "default"
      })

    assert_receive {:gateway_event, payload}
    assert payload.type == "task_schedule_triggered"
    assert payload.schedule_id == "schedule-1"
    assert payload.fire_time == "2026-02-25T12:00:00Z"
    assert payload.idempotency_key == "schedule-1:2026-02-25T12:00:00Z"
    assert payload.schedule_type == "at"
    assert payload.triggered_at == "2026-02-25T12:00:01Z"
    assert payload.metadata.trace_id == "trace-1"
    assert payload.metadata["tenant"] == "default"
  end
end
