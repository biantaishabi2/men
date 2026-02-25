defmodule Men.Gateway.TaskDispatcherTest do
  use ExUnit.Case, async: false

  alias Men.Gateway.DispatchServer
  alias Men.Gateway.TaskDispatcher

  defmodule FastBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, _context) do
      {:ok, %{text: "ok:" <> to_string(prompt), meta: %{source: :fast_bridge}}}
    end
  end

  defmodule NoopEgress do
    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(_target, _message), do: :ok
  end

  test "同 schedule_id+fire_time 仅发布一次" do
    topic = "task_dispatcher_dedup_#{System.unique_integer([:positive, :monotonic])}"
    :ok = Men.Gateway.EventBus.subscribe(topic)

    dispatcher =
      start_supervised!(
        {TaskDispatcher,
         [
           name: {:global, {__MODULE__, :dedup, self(), make_ref()}},
           event_bus_topic: topic,
           dedup_ttl_ms: :timer.minutes(5),
           max_concurrency: 10
         ]}
      )

    fire_time = ~U[2026-02-25 12:00:00Z]

    :ok =
      TaskDispatcher.dispatch(dispatcher, %{
        schedule_id: "schedule-dedup-1",
        schedule_type: :at,
        fire_time: fire_time,
        metadata: %{trace_id: "trace-dedup-1"}
      })

    :ok =
      TaskDispatcher.dispatch(dispatcher, %{
        schedule_id: "schedule-dedup-1",
        schedule_type: :at,
        fire_time: fire_time,
        metadata: %{trace_id: "trace-dedup-1"}
      })

    assert_receive {:gateway_event, payload}
    assert payload.schedule_id == "schedule-dedup-1"
    assert payload.fire_time == "2026-02-25T12:00:00Z"
    assert payload.idempotency_key == "schedule-dedup-1:2026-02-25T12:00:00Z"

    refute_receive {:gateway_event, %{schedule_id: "schedule-dedup-1"}}

    stats = TaskDispatcher.stats(dispatcher)
    assert stats.dispatched_count == 1
    assert stats.duplicate_count == 1
  end

  test "高并发到期任务触发时受并发上限与背压控制且不阻塞 DispatchServer" do
    topic = "task_dispatcher_concurrency_#{System.unique_integer([:positive, :monotonic])}"
    parent = self()

    publish_fun = fn _topic, payload ->
      send(parent, {:task_dispatch_published, payload.schedule_id})
      Process.sleep(120)
      :ok
    end

    dispatcher =
      start_supervised!(
        {TaskDispatcher,
         [
           name: {:global, {__MODULE__, :concurrency, self(), make_ref()}},
           event_bus_topic: topic,
           dedup_ttl_ms: :timer.minutes(5),
           max_concurrency: 5,
           publish_fun: publish_fun
         ]}
      )

    fire_time = ~U[2026-02-25 12:00:00Z]

    Enum.each(1..100, fn index ->
      :ok =
        TaskDispatcher.dispatch(dispatcher, %{
          schedule_id: "schedule-concurrency-#{index}",
          schedule_type: :at,
          fire_time: fire_time,
          metadata: %{batch: "load-test"}
        })
    end)

    Process.sleep(40)

    stats = TaskDispatcher.stats(dispatcher)
    assert stats.inflight <= 5
    assert stats.dropped_count >= 90

    dispatch_server =
      start_supervised!(
        {DispatchServer,
         [
           name: {:global, {__MODULE__, :dispatch_server, self(), make_ref()}},
           bridge_adapter: FastBridge,
           egress_adapter: NoopEgress,
           session_coordinator_enabled: false,
           event_coordination_enabled: false,
           wake_enabled: false
         ]}
      )

    {cost_us, dispatch_result} =
      :timer.tc(fn ->
        DispatchServer.dispatch(dispatch_server, %{
          request_id: "request-concurrency-1",
          payload: "hello",
          metadata: %{source: :test},
          channel: "feishu",
          user_id: "u100"
        })
      end)

    assert {:ok, _result} = dispatch_result
    assert cost_us < 400_000
  end
end
