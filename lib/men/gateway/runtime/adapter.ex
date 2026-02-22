defmodule Men.Gateway.Runtime.Adapter do
  @moduledoc """
  JIT 运行时适配层：统一封装三图调用、Advisor 决策与 Snapshot 构建。
  """

  alias Men.Gateway.Runtime.{FrameSnapshotBuilder, ModeStateMachine, Telemetry}
  alias Men.RuntimeBridge.Bridge
  alias Men.RuntimeBridge.ErrorResponse

  @type jit_flag :: :jit_enabled | :jit_disabled | :smoke_mode

  @type cycle_result :: %{
          required(:trace_id) => binary(),
          required(:session_id) => binary(),
          required(:flag_state) => jit_flag(),
          required(:advisor_decision) => atom(),
          required(:snapshot_action) => atom(),
          required(:rollback_reason) => atom() | nil,
          required(:mode) => ModeStateMachine.mode(),
          required(:mode_context) => ModeStateMachine.context(),
          required(:snapshot) => FrameSnapshotBuilder.FrameSnapshot.t(),
          required(:loop_status) => :running,
          required(:degraded?) => boolean(),
          required(:graph_results) => map(),
          optional(:fallback_path) => :fixed_orchestration
        }

  @spec orchestrate(map(), keyword()) :: {:ok, cycle_result()} | {:error, map()}
  def orchestrate(runtime_state, opts \\ []) when is_map(runtime_state) and is_list(opts) do
    trace_id =
      opts[:trace_id] || "trace-" <> Integer.to_string(System.unique_integer([:positive]))

    session_id = opts[:session_id] || Map.get(runtime_state, :session_id, "unknown-session")

    flag_state =
      resolve_flag(opts[:jit_flag] || Application.get_env(:men, :jit_feature_flag, :jit_enabled))

    base_telemetry = %{
      trace_id: trace_id,
      session_id: session_id,
      flag_state: flag_state,
      advisor_decision: :hold,
      snapshot_action: :injected,
      rollback_reason: nil
    }

    case flag_state do
      :jit_disabled ->
        result = fallback_result(runtime_state, trace_id, session_id, flag_state)

        :ok =
          Telemetry.emit(:degraded, Map.merge(base_telemetry, result_telemetry_fields(result)))

        :ok =
          Telemetry.emit(
            :cycle_completed,
            Map.merge(base_telemetry, result_telemetry_fields(result))
          )

        {:ok, result}

      :smoke_mode ->
        run_cycle(
          runtime_state,
          opts,
          trace_id,
          session_id,
          flag_state,
          [:research_reduce],
          base_telemetry
        )

      :jit_enabled ->
        run_cycle(
          runtime_state,
          opts,
          trace_id,
          session_id,
          flag_state,
          [:research_reduce, :execute_compile],
          base_telemetry
        )
    end
  end

  defp run_cycle(runtime_state, opts, trace_id, session_id, flag_state, actions, base_telemetry) do
    with {:ok, graph_results} <- run_graph_pipeline(actions, runtime_state, opts, base_telemetry),
         {:ok, result} <-
           decide_and_snapshot(
             runtime_state,
             opts,
             trace_id,
             session_id,
             flag_state,
             graph_results,
             base_telemetry
           ) do
      :ok =
        Telemetry.emit(
          :cycle_completed,
          Map.merge(base_telemetry, result_telemetry_fields(result))
        )

      {:ok, result}
    else
      {:error, reason} ->
        degrade_to_fallback(
          runtime_state,
          trace_id,
          session_id,
          flag_state,
          reason,
          base_telemetry
        )
    end
  end

  defp run_graph_pipeline(actions, runtime_state, opts, telemetry) do
    Enum.reduce_while(actions, {:ok, %{}}, fn action, {:ok, acc} ->
      payload = graph_payload(action, runtime_state)

      :ok =
        Telemetry.emit(
          :graph_invoked,
          Map.merge(telemetry, %{advisor_decision: action, snapshot_action: :pending})
        )

      case invoke_graph(action, payload, opts) do
        {:ok, normalized} ->
          {:cont, {:ok, Map.put(acc, action, normalized)}}

        {:error, reason} ->
          {:halt, {:error, {:graph_failed, action, reason}}}
      end
    end)
  end

  defp decide_and_snapshot(
         runtime_state,
         opts,
         trace_id,
         session_id,
         flag_state,
         graph_results,
         base_telemetry
       ) do
    current_mode = opts[:current_mode] || Map.get(runtime_state, :current_mode, :research)
    mode_context = opts[:mode_context] || ModeStateMachine.initial_context()

    mode_options =
      opts
      |> Keyword.get(:mode_state_machine_options, %{})
      |> Map.new()
      |> Map.put(:apply_mode?, Keyword.get(opts, :mode_policy_apply, false))

    snapshot_signals = build_mode_snapshot(graph_results, runtime_state, opts)

    {next_mode, next_context, decision_meta} =
      ModeStateMachine.decide(current_mode, snapshot_signals, mode_context, mode_options)

    rollback_reason = rollback_reason(decision_meta)
    snapshot_action = if rollback_reason, do: :rebuilt, else: :injected

    :ok =
      Telemetry.emit(
        :advisor_decided,
        Map.merge(base_telemetry, %{
          advisor_decision: decision_meta.recommended_mode,
          snapshot_action: snapshot_action,
          rollback_reason: rollback_reason
        })
      )

    if rollback_reason do
      :ok =
        Telemetry.emit(
          :rollback_triggered,
          Map.merge(base_telemetry, %{
            advisor_decision: decision_meta.recommended_mode,
            snapshot_action: :rebuilt,
            rollback_reason: rollback_reason
          })
        )
    end

    snapshot_type = choose_snapshot_type(next_mode, rollback_reason)

    snapshot_state =
      runtime_state
      |> Map.put(
        :recommendations,
        snapshot_recommendations(decision_meta, graph_results, rollback_reason)
      )
      |> Map.put(:event_ids, build_event_ids(trace_id, session_id, decision_meta))
      |> Map.put(:node_ids, build_node_ids(graph_results, decision_meta))

    snapshot =
      FrameSnapshotBuilder.build(snapshot_state, snapshot_type: snapshot_type, debug: true)

    :ok =
      Telemetry.emit(
        :snapshot_generated,
        Map.merge(base_telemetry, %{
          advisor_decision: decision_meta.recommended_mode,
          snapshot_action: snapshot_action,
          rollback_reason: rollback_reason
        })
      )

    {:ok,
     %{
       trace_id: trace_id,
       session_id: session_id,
       flag_state: flag_state,
       advisor_decision: decision_meta.recommended_mode,
       snapshot_action: snapshot_action,
       rollback_reason: rollback_reason,
       mode: next_mode,
       mode_context: next_context,
       mode_meta: decision_meta,
       snapshot: snapshot,
       graph_results: graph_results,
       loop_status: :running,
       degraded?: false
     }}
  end

  defp degrade_to_fallback(
         runtime_state,
         trace_id,
         session_id,
         flag_state,
         reason,
         base_telemetry
       ) do
    result =
      runtime_state
      |> fallback_result(trace_id, session_id, flag_state)
      |> Map.put(:degraded?, true)
      |> Map.put(:degrade_reason, map_error(reason))

    :ok =
      Telemetry.emit(
        :degraded,
        Map.merge(
          base_telemetry,
          Map.merge(result_telemetry_fields(result), %{rollback_reason: :degraded})
        )
      )

    :ok =
      Telemetry.emit(
        :cycle_completed,
        Map.merge(
          base_telemetry,
          Map.merge(result_telemetry_fields(result), %{rollback_reason: :degraded})
        )
      )

    {:ok, result}
  end

  defp fallback_result(runtime_state, trace_id, session_id, flag_state) do
    snapshot =
      FrameSnapshotBuilder.build(runtime_state,
        snapshot_type: :idle_snapshot,
        debug: false
      )

    %{
      trace_id: trace_id,
      session_id: session_id,
      flag_state: flag_state,
      advisor_decision: :fixed_path,
      snapshot_action: :fixed_path,
      rollback_reason: nil,
      mode: :research,
      mode_context: ModeStateMachine.initial_context(),
      snapshot: snapshot,
      graph_results: %{},
      loop_status: :running,
      degraded?: true,
      fallback_path: :fixed_orchestration
    }
  end

  defp resolve_flag(:jit_enabled), do: :jit_enabled
  defp resolve_flag(:jit_disabled), do: :jit_disabled
  defp resolve_flag(:smoke_mode), do: :smoke_mode
  defp resolve_flag("jit_enabled"), do: :jit_enabled
  defp resolve_flag("jit_disabled"), do: :jit_disabled
  defp resolve_flag("smoke_mode"), do: :smoke_mode
  defp resolve_flag(_), do: :jit_enabled

  defp invoke_graph(action, payload, opts) do
    if runner = opts[:graph_runner] do
      normalize_graph_result(action, runner.(action, payload))
    else
      normalize_graph_result(
        action,
        Bridge.graph(action, payload, Keyword.take(opts, [:graph_adapter, :cmd, :taskctl_args]))
      )
    end
  end

  defp normalize_graph_result(_action, {:ok, %{} = result}), do: {:ok, result}

  defp normalize_graph_result(_action, {:error, %ErrorResponse{} = error}),
    do: {:error, map_error(error)}

  defp normalize_graph_result(_action, {:error, reason}) when is_binary(reason),
    do: {:error, %{code: "graph_error", message: reason, details: %{}}}

  defp normalize_graph_result(_action, other),
    do:
      {:error,
       %{code: "graph_error", message: "unexpected graph result", details: %{raw: inspect(other)}}}

  defp graph_payload(:research_reduce, runtime_state) do
    %{
      state: Map.get(runtime_state, :research_state, %{}),
      events: Map.get(runtime_state, :research_events, [])
    }
  end

  defp graph_payload(:execute_compile, runtime_state) do
    %{
      tasks: Map.get(runtime_state, :execute_tasks, []),
      edges: Map.get(runtime_state, :execute_edges, [])
    }
  end

  defp build_mode_snapshot(graph_results, runtime_state, opts) do
    research_diff = get_in(graph_results, [:research_reduce, :data, "diff"]) || %{}

    mode_signals =
      opts
      |> Keyword.get(:mode_signals, %{})
      |> Map.new()

    %{
      blocking_count:
        research_diff
        |> Map.get("blocking_added", [])
        |> List.wrap()
        |> length(),
      key_claim_confidence: read_confidence(runtime_state),
      graph_change_rate: Map.get(runtime_state, :graph_change_rate, 0.01),
      execute_compilable: execute_compilable?(graph_results),
      premise_invalidated: Map.get(mode_signals, :premise_invalidated, false),
      external_mutation: Map.get(mode_signals, :external_mutation, false),
      invalidated_premise_ids: Map.get(mode_signals, :invalidated_premise_ids, []),
      critical_paths_by_premise: Map.get(mode_signals, :critical_paths_by_premise, %{}),
      total_critical_paths: Map.get(mode_signals, :total_critical_paths, 0),
      uncovered_critical_paths: Map.get(mode_signals, :uncovered_critical_paths, 0)
    }
  end

  defp read_confidence(runtime_state) do
    runtime_state
    |> Map.get(:key_claim_confidence, 0.0)
    |> case do
      value when is_float(value) -> value
      value when is_integer(value) -> value * 1.0
      _ -> 0.0
    end
  end

  defp execute_compilable?(graph_results) do
    case Map.get(graph_results, :execute_compile) do
      %{"result" => "ok"} -> true
      %{result: "ok"} -> true
      %{"result" => "compiled"} -> true
      %{result: "compiled"} -> true
      nil -> false
      _ -> false
    end
  end

  defp rollback_reason(%{reason: reason, from_mode: :execute, recommended_mode: :research})
       when reason in [:premise_invalidated, :external_mutation, :info_insufficient],
       do: reason

  defp rollback_reason(_), do: nil

  defp choose_snapshot_type(:execute, nil), do: :action_snapshot
  defp choose_snapshot_type(:research, nil), do: :handoff_snapshot
  defp choose_snapshot_type(_, _rollback_reason), do: :idle_snapshot

  defp snapshot_recommendations(decision_meta, graph_results, rollback_reason) do
    base =
      [
        %{
          text: "advisor: #{decision_meta.recommended_mode}",
          priority: decision_meta.priority || :normal,
          source: :mode_advisor
        }
      ]

    rollback_recommendation =
      if rollback_reason do
        [
          %{
            text: "rollback: #{rollback_reason}",
            priority: :high,
            source: :rollback_guard
          }
        ]
      else
        []
      end

    graph_recommendation =
      graph_results
      |> Map.get(:research_reduce, %{})
      |> Map.get(:diagnostics, %{})
      |> case do
        %{} = diagnostics when map_size(diagnostics) > 0 ->
          [
            %{
              text: "diagnostics captured",
              priority: :normal,
              source: :graph_diagnostics
            }
          ]

        _ ->
          []
      end

    base ++ rollback_recommendation ++ graph_recommendation
  end

  defp build_event_ids(trace_id, session_id, decision_meta) do
    [
      "trace:#{trace_id}",
      "session:#{session_id}",
      "tick:#{decision_meta.tick}"
    ]
  end

  defp build_node_ids(graph_results, decision_meta) do
    graph_nodes =
      graph_results
      |> Map.keys()
      |> Enum.map(&Atom.to_string/1)

    graph_nodes ++ ["mode:#{decision_meta.recommended_mode}"]
  end

  defp map_error(%ErrorResponse{} = error) do
    %{
      code: error.code || "graph_error",
      message: error.reason,
      details: Map.get(error, :metadata, %{})
    }
  end

  defp map_error({:graph_failed, action, reason}) do
    %{
      code: "graph_failed",
      message: "graph action failed: #{action}",
      details: %{reason: inspect(reason)}
    }
  end

  defp map_error(reason) when is_map(reason), do: reason

  defp map_error(reason) do
    %{
      code: "jit_runtime_error",
      message: "jit orchestration failed",
      details: %{reason: inspect(reason)}
    }
  end

  defp result_telemetry_fields(result) do
    %{
      advisor_decision: Map.get(result, :advisor_decision, :hold),
      snapshot_action: Map.get(result, :snapshot_action, :injected),
      rollback_reason: Map.get(result, :rollback_reason)
    }
  end
end
