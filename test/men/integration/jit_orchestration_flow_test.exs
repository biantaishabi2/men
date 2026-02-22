defmodule Men.Integration.JitOrchestrationFlowTest do
  use ExUnit.Case, async: false

  alias Men.Gateway.Runtime.Adapter
  alias Men.Gateway.Runtime.ModeStateMachine

  @event_prefix [:men, :gateway, :runtime, :jit, :v1]

  setup do
    handler_id = "jit-flow-#{System.unique_integer([:positive, :monotonic])}"

    events = [
      @event_prefix ++ [:graph_invoked],
      @event_prefix ++ [:advisor_decided],
      @event_prefix ++ [:snapshot_generated],
      @event_prefix ++ [:cycle_completed]
    ]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, pid ->
          send(pid, {:jit_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  test "初始断键任务在 jit_enabled 下完成建议-采纳-快照注入闭环" do
    runtime_state = %{
      goal: "修复断键任务",
      policy: %{mode: :jit, strict: true},
      current_focus: %{text: "先补齐 research 再推进 execute", refs: ["issue-34", "issue-37"]},
      next_candidates: [%{id: "step-1", title: "补证据"}, %{id: "step-2", title: "编排执行"}],
      constraints: [%{text: "保持主循环不中断", active: true}],
      key_claim_confidence: 0.95,
      graph_change_rate: 0.01,
      research_state: %{claims: %{}},
      research_events: [%{claim_id: "c-1", action: :support, source_weight: 1.0}],
      execute_tasks: [%{task_id: "t-1", blocked_by: []}, %{task_id: "t-2", blocked_by: ["t-1"]}],
      execute_edges: [%{from: "t-1", to: "t-2"}]
    }

    graph_runner = fn
      :research_reduce, _payload ->
        {:ok,
         %{
           result: "ok",
           data: %{"diff" => %{"blocking_added" => []}},
           diagnostics: %{"source" => "mock-research"}
         }}

      :execute_compile, _payload ->
        {:ok,
         %{
           result: "compiled",
           data: %{"layers" => [["t-1"], ["t-2"]]},
           diagnostics: %{"source" => "mock-execute"}
         }}
    end

    assert {:ok, result} =
             Adapter.orchestrate(runtime_state,
               trace_id: "trace-flow-1",
               session_id: "session-flow-1",
               jit_flag: :jit_enabled,
               graph_runner: graph_runner,
               current_mode: :research,
               mode_context: ModeStateMachine.initial_context(),
               mode_policy_apply: true,
               mode_state_machine_options: %{stable_window_ticks: 1, enter_threshold: 0.75}
             )

    assert result.mode == :execute
    assert result.advisor_decision == :execute
    assert result.snapshot_action == :injected
    assert result.rollback_reason == nil
    assert result.loop_status == :running
    assert result.degraded? == false
    assert Map.has_key?(result.graph_results, :research_reduce)
    assert Map.has_key?(result.graph_results, :execute_compile)

    assert result.snapshot.goal == "修复断键任务"
    assert result.snapshot.snapshot_type == :action_snapshot
    assert result.snapshot.state_ref.event_id == "trace:trace-flow-1"

    telemetry_events = collect_telemetry_events(6)

    assert_event_present?(telemetry_events, @event_prefix ++ [:graph_invoked])
    assert_event_present?(telemetry_events, @event_prefix ++ [:advisor_decided])
    assert_event_present?(telemetry_events, @event_prefix ++ [:snapshot_generated])
    assert_event_present?(telemetry_events, @event_prefix ++ [:cycle_completed])

    assert Enum.all?(telemetry_events, fn {_event, _m, metadata} ->
             metadata.trace_id == "trace-flow-1" and
               metadata.session_id == "session-flow-1" and
               Map.has_key?(metadata, :flag_state) and
               Map.has_key?(metadata, :advisor_decision) and
               Map.has_key?(metadata, :snapshot_action) and
               Map.has_key?(metadata, :rollback_reason)
           end)
  end

  defp collect_telemetry_events(max_count, acc \\ [])

  defp collect_telemetry_events(0, acc), do: Enum.reverse(acc)

  defp collect_telemetry_events(max_count, acc) do
    receive do
      {:jit_telemetry, event, measurements, metadata} ->
        collect_telemetry_events(max_count - 1, [{event, measurements, metadata} | acc])
    after
      120 ->
        Enum.reverse(acc)
    end
  end

  defp assert_event_present?(events, event_name) do
    assert Enum.any?(events, fn {event, _, _} -> event == event_name end)
  end
end
