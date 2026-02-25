defmodule Men.Gateway.TaskSchedulerTest do
  use ExUnit.Case, async: false

  alias Men.Gateway.EventBus
  alias Men.Gateway.TaskDispatcher
  alias Men.Gateway.TaskScheduler

  test "到期单次触发: at 任务到点仅投递一次" do
    topic = "task_scheduler_at_#{System.unique_integer([:positive, :monotonic])}"
    :ok = EventBus.subscribe(topic)

    base_time = ~U[2026-02-25 12:00:00Z]
    {:ok, clock} = Agent.start_link(fn -> DateTime.to_unix(base_time, :millisecond) end)
    {:ok, schedules} = Agent.start_link(fn -> [] end)

    dispatcher =
      start_supervised!(
        {TaskDispatcher,
         [
           name: {:global, {__MODULE__, :dispatcher_at, self(), make_ref()}},
           event_bus_topic: topic,
           max_concurrency: 100
         ]}
      )

    scheduler =
      start_supervised!(
        {TaskScheduler,
         [
           name: {:global, {__MODULE__, :scheduler_at, self(), make_ref()}},
           dispatcher: dispatcher,
           auto_tick?: false,
           tick_interval_ms: 1_000,
           schedule_source: fn -> Agent.get(schedules, & &1) end,
           clock: fn -> Agent.get(clock, &DateTime.from_unix!(&1, :millisecond)) end
         ]}
      )

    Agent.update(schedules, fn _ ->
      [
        %{
          schedule_id: "schedule-at-1",
          schedule_type: :at,
          next_run_at: DateTime.add(base_time, 10, :second),
          metadata: %{source: "test_at"}
        }
      ]
    end)

    assert {:ok, 0} = TaskScheduler.trigger_tick(scheduler)

    Agent.update(clock, fn _ ->
      DateTime.to_unix(DateTime.add(base_time, 10, :second), :millisecond)
    end)

    assert {:ok, 1} = TaskScheduler.trigger_tick(scheduler)

    assert_receive {:gateway_event, payload}
    assert payload.schedule_id == "schedule-at-1"
    assert payload.fire_time == "2026-02-25T12:00:10Z"
    assert payload.idempotency_key == "schedule-at-1:2026-02-25T12:00:10Z"

    Agent.update(clock, fn _ ->
      DateTime.to_unix(DateTime.add(base_time, 11, :second), :millisecond)
    end)

    assert {:ok, 0} = TaskScheduler.trigger_tick(scheduler)
    refute_receive {:gateway_event, %{schedule_id: "schedule-at-1"}}
  end

  test "Scheduler 异常退出后重启可补跑 catchup window 内遗漏任务" do
    topic = "task_scheduler_restart_#{System.unique_integer([:positive, :monotonic])}"
    :ok = EventBus.subscribe(topic)

    base_time = ~U[2026-02-25 12:00:00Z]
    {:ok, clock} = Agent.start_link(fn -> DateTime.to_unix(base_time, :millisecond) end)
    {:ok, schedules} = Agent.start_link(fn -> [] end)

    dispatcher_name = {:global, {__MODULE__, :dispatcher_restart, self(), make_ref()}}

    start_supervised!(
      {TaskDispatcher,
       [
         name: dispatcher_name,
         event_bus_topic: topic,
         max_concurrency: 100
       ]}
    )

    Agent.update(schedules, fn _ ->
      [
        %{
          schedule_id: "schedule-restart-1",
          schedule_type: :at,
          next_run_at: DateTime.add(base_time, 5, :second),
          metadata: %{source: "test_restart"}
        }
      ]
    end)

    scheduler_name = {:global, {__MODULE__, :scheduler_restart, self(), make_ref()}}

    supervisor =
      start_supervised!(
        {DynamicSupervisor,
         strategy: :one_for_one,
         name: {:global, {__MODULE__, :scheduler_supervisor, self(), make_ref()}}}
      )

    assert {:ok, _child_pid} =
             DynamicSupervisor.start_child(
               supervisor,
               {TaskScheduler,
                [
                  name: scheduler_name,
                  dispatcher: dispatcher_name,
                  auto_tick?: false,
                  tick_interval_ms: 1_000,
                  schedule_source: fn -> Agent.get(schedules, & &1) end,
                  clock: fn -> Agent.get(clock, &DateTime.from_unix!(&1, :millisecond)) end
                ]}
             )

    old_pid = GenServer.whereis(scheduler_name)
    assert is_pid(old_pid)
    Process.exit(old_pid, :kill)

    new_pid = wait_for_restarted_pid(scheduler_name, old_pid)
    assert is_pid(new_pid)

    Agent.update(clock, fn _ ->
      DateTime.to_unix(DateTime.add(base_time, 7, :second), :millisecond)
    end)

    assert {:ok, 1} = TaskScheduler.trigger_tick(scheduler_name)

    assert_receive {:gateway_event, payload}
    assert payload.schedule_id == "schedule-restart-1"
    assert payload.fire_time == "2026-02-25T12:00:05Z"
  end

  test "daily 语法糖归一化为 UTC cron 0 0 * * * 并按 cron 触发" do
    topic = "task_scheduler_daily_#{System.unique_integer([:positive, :monotonic])}"
    :ok = EventBus.subscribe(topic)

    base_time = ~U[2026-02-25 00:00:30Z]
    {:ok, clock} = Agent.start_link(fn -> DateTime.to_unix(base_time, :millisecond) end)
    {:ok, schedules} = Agent.start_link(fn -> [] end)

    dispatcher =
      start_supervised!(
        {TaskDispatcher,
         [
           name: {:global, {__MODULE__, :dispatcher_daily, self(), make_ref()}},
           event_bus_topic: topic,
           max_concurrency: 100
         ]}
      )

    scheduler =
      start_supervised!(
        {TaskScheduler,
         [
           name: {:global, {__MODULE__, :scheduler_daily, self(), make_ref()}},
           dispatcher: dispatcher,
           auto_tick?: false,
           tick_interval_ms: 1_000,
           schedule_source: fn -> Agent.get(schedules, & &1) end,
           clock: fn -> Agent.get(clock, &DateTime.from_unix!(&1, :millisecond)) end
         ]}
      )

    Agent.update(schedules, fn _ ->
      [
        %{
          schedule_id: "schedule-daily-1",
          schedule_type: :daily,
          next_run_at: ~U[2026-02-25 00:00:00Z],
          metadata: %{source: "test_daily"}
        }
      ]
    end)

    assert {:ok, normalized} =
             TaskScheduler.normalize_schedule(%{
               schedule_id: "schedule-daily-normalize",
               schedule_type: :daily,
               next_run_at: ~U[2026-02-25 00:00:00Z]
             })

    assert normalized.schedule_type == :cron
    assert normalized.cron_expr == "0 0 * * *"

    assert {:ok, 1} = TaskScheduler.trigger_tick(scheduler)

    assert_receive {:gateway_event, payload}
    assert payload.schedule_id == "schedule-daily-1"
    assert payload.fire_time == "2026-02-25T00:00:00Z"
    assert payload.schedule_type == "cron"
  end

  defp wait_for_restarted_pid(name, old_pid, attempts \\ 20)

  defp wait_for_restarted_pid(_name, _old_pid, 0), do: nil

  defp wait_for_restarted_pid(name, old_pid, attempts) do
    case GenServer.whereis(name) do
      nil ->
        Process.sleep(20)
        wait_for_restarted_pid(name, old_pid, attempts - 1)

      ^old_pid ->
        Process.sleep(20)
        wait_for_restarted_pid(name, old_pid, attempts - 1)

      pid when is_pid(pid) ->
        pid
    end
  end
end
