defmodule Men.Integration.JitOrchestrationRollbackTest do
  use ExUnit.Case, async: false

  alias Men.Gateway.Runtime.Adapter
  alias Men.Gateway.Runtime.ModeStateMachine

  @event_prefix [:men, :gateway, :runtime, :jit, :v1]

  setup do
    handler_id = "jit-rollback-#{System.unique_integer([:positive, :monotonic])}"

    events = [
      @event_prefix ++ [:advisor_decided],
      @event_prefix ++ [:rollback_triggered],
      @event_prefix ++ [:degraded],
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

  test "执行中前提失效触发回滚建议与快照重建，主循环不中断" do
    runtime_state = %{
      goal: "执行关键补丁",
      policy: %{mode: :jit, strict: true},
      current_focus: %{text: "执行阶段发生依赖失效", refs: ["premise-1"]},
      next_candidates: [%{id: "rollback-1", title: "回到 research"}],
      constraints: [%{text: "不能中断主循环", active: true}],
      key_claim_confidence: 0.91,
      graph_change_rate: 0.01,
      research_state: %{claims: %{}},
      research_events: [],
      execute_tasks: [%{task_id: "task-a", blocked_by: []}],
      execute_edges: []
    }

    graph_runner = fn
      :research_reduce, _payload ->
        {:ok, %{result: "ok", data: %{"diff" => %{"blocking_added" => []}}, diagnostics: %{}}}

      :execute_compile, _payload ->
        {:ok, %{result: "compiled", data: %{"layers" => [["task-a"]]}, diagnostics: %{}}}
    end

    assert {:ok, result} =
             Adapter.orchestrate(runtime_state,
               trace_id: "trace-rollback-1",
               session_id: "session-rollback-1",
               jit_flag: :jit_enabled,
               graph_runner: graph_runner,
               current_mode: :execute,
               mode_context: ModeStateMachine.initial_context(),
               mode_policy_apply: true,
               mode_signals: %{
                 premise_invalidated: true,
                 invalidated_premise_ids: ["premise-1"],
                 critical_paths_by_premise: %{"premise-1" => ["path-a"]}
               }
             )

    assert result.mode == :research
    assert result.advisor_decision == :research
    assert result.snapshot_action == :rebuilt
    assert result.rollback_reason == :premise_invalidated
    assert result.loop_status == :running
    assert result.degraded? == false
    assert result.snapshot.snapshot_type == :idle_snapshot

    assert Enum.any?(result.snapshot.recommendations, fn recommendation ->
             String.contains?(recommendation.text, "rollback")
           end)

    telemetry_events = collect_telemetry_events(6)

    assert_event_present?(telemetry_events, @event_prefix ++ [:advisor_decided])
    assert_event_present?(telemetry_events, @event_prefix ++ [:rollback_triggered])
    assert_event_present?(telemetry_events, @event_prefix ++ [:cycle_completed])
  end

  test "jit_disabled 时降级固定编排路径并保持可用" do
    runtime_state = %{
      goal: "降级验证",
      policy: %{mode: :stable}
    }

    assert {:ok, result} =
             Adapter.orchestrate(runtime_state,
               trace_id: "trace-disabled-1",
               session_id: "session-disabled-1",
               jit_flag: :jit_disabled
             )

    assert result.mode == :research
    assert result.advisor_decision == :fixed_path
    assert result.snapshot_action == :fixed_path
    assert result.degraded? == true
    assert result.fallback_path == :fixed_orchestration

    telemetry_events = collect_telemetry_events(4)
    assert_event_present?(telemetry_events, @event_prefix ++ [:degraded])
    assert_event_present?(telemetry_events, @event_prefix ++ [:cycle_completed])
  end

  test "图执行失败时降级到固定编排路径并发出 degraded 事件" do
    runtime_state = %{
      goal: "图失败降级验证",
      policy: %{mode: :jit}
    }

    graph_runner = fn
      :research_reduce, _payload -> {:error, "research crashed"}
      :execute_compile, _payload -> {:ok, %{result: "compiled", data: %{}, diagnostics: %{}}}
    end

    assert {:ok, result} =
             Adapter.orchestrate(runtime_state,
               trace_id: "trace-graph-failed-1",
               session_id: "session-graph-failed-1",
               jit_flag: :jit_enabled,
               graph_runner: graph_runner
             )

    assert result.degraded? == true
    assert result.fallback_path == :fixed_orchestration
    assert result.flag_state == :jit_enabled
    assert result.advisor_decision == :fixed_path
    assert result.snapshot_action == :fixed_path
    assert result.degrade_reason.code == "graph_failed"

    telemetry_events = collect_telemetry_events(6)
    assert_event_present?(telemetry_events, @event_prefix ++ [:degraded])
    assert_event_present?(telemetry_events, @event_prefix ++ [:cycle_completed])
  end

  test "replay 脚本参数缺值时返回受控错误而非 unbound variable 崩溃" do
    script_path = Path.expand("scripts/jit/replay.sh", File.cwd!())
    {output, status} = System.cmd("bash", [script_path, "--input"], stderr_to_stdout: true)

    assert status == 1
    assert output =~ "参数 --input 缺少值"
    assert output =~ "用法"
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
