defmodule Men.Gateway.DispatchServer do
  @moduledoc """
  L1 主状态机：串联 inbound -> runtime bridge -> egress。
  """

  use GenServer

  require Logger

  alias Men.Channels.Egress.Messages.{ErrorMessage, FinalMessage}
  alias Men.Dispatch.CutoverPolicy
  alias Men.Gateway.EventEnvelope
  alias Men.Gateway.InboxStore
  alias Men.Gateway.OpsPolicyProvider
  alias Men.Gateway.ReplStore
  alias Men.Gateway.Runtime.Adapter
  alias Men.Gateway.Runtime.ModeStateMachine
  alias Men.Gateway.SessionCoordinator
  alias Men.Gateway.Types
  alias Men.Gateway.WakePolicy
  alias Men.Routing.SessionKey

  @type terminal_reply :: {:ok, Types.dispatch_result()} | {:error, Types.error_result()}

  @type state :: %{
          bridge_adapter: module(),
          legacy_bridge_adapter: module() | nil,
          zcpg_client: module() | nil,
          zcpg_cutover_config: keyword(),
          egress_adapter: module(),
          storage_adapter: term(),
          session_coordinator_enabled: boolean(),
          session_coordinator_name: GenServer.server(),
          session_rebuild_retry_enabled: boolean(),
          event_coordination_enabled: boolean(),
          wake_enabled: boolean(),
          ops_policy_provider: module(),
          ops_policy_identity: map(),
          inbox_store_opts: keyword(),
          repl_store_opts: keyword(),
          rebuild_target: GenServer.server() | nil,
          rebuild_notify_pid: pid() | nil,
          mode_state_machine_enabled: boolean(),
          mode_policy_apply: boolean(),
          mode_state_machine: module(),
          mode_state_machine_mode: ModeStateMachine.mode(),
          mode_state_machine_context: ModeStateMachine.context(),
          mode_state_machine_options: map(),
          mode_transition_topic: binary(),
          mode_transition_suppression_window_ticks: non_neg_integer(),
          mode_transition_suppression_limit: non_neg_integer(),
          mode_transition_recovery_ticks: non_neg_integer(),
          runtime_adapter: module(),
          jit_feature_flag: Adapter.jit_flag(),
          run_terminal_limit: pos_integer(),
          run_terminal_order: :queue.queue(binary()),
          session_last_context: %{optional(binary()) => Types.run_context()},
          run_terminal_results: %{optional(binary()) => terminal_reply()}
        }

  defmodule NoopEgress do
    @moduledoc """
    默认 egress adapter（无副作用）。
    """

    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(_target, _message), do: :ok
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec dispatch(GenServer.server(), Types.inbound_event()) ::
          {:ok, Types.dispatch_result()} | {:error, Types.error_result()}
  def dispatch(server \\ __MODULE__, inbound_event) do
    GenServer.call(server, {:dispatch, inbound_event})
  end

  @spec coordinate_event(GenServer.server(), map() | EventEnvelope.t(), keyword() | map()) ::
          {:ok,
           %{
             envelope: EventEnvelope.t(),
             store_result: :ok | :duplicate | :stale,
             rebuild_triggered: boolean()
           }}
          | {:error, term()}
  def coordinate_event(server \\ __MODULE__, event, runtime_overrides \\ %{}) do
    GenServer.call(server, {:coordinate_event, event, runtime_overrides})
  end

  @spec enqueue(GenServer.server(), Types.inbound_event()) ::
          :ok | {:error, :dispatch_server_unavailable}
  def enqueue(server \\ __MODULE__, inbound_event) do
    case GenServer.whereis(server) do
      nil ->
        {:error, :dispatch_server_unavailable}

      _pid ->
        GenServer.cast(server, {:enqueue, inbound_event})
        :ok
    end
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:men, __MODULE__, [])
    coordinator_config = Application.get_env(:men, SessionCoordinator, [])

    state = %{
      bridge_adapter: Keyword.get(opts, :bridge_adapter, Keyword.fetch!(config, :bridge_adapter)),
      legacy_bridge_adapter:
        Keyword.get(opts, :legacy_bridge_adapter, Keyword.get(config, :legacy_bridge_adapter)),
      zcpg_client: Keyword.get(opts, :zcpg_client, Keyword.get(config, :zcpg_client)),
      zcpg_cutover_config:
        Keyword.get(opts, :zcpg_cutover_config, Application.get_env(:men, :zcpg_cutover, [])),
      egress_adapter: Keyword.get(opts, :egress_adapter, Keyword.fetch!(config, :egress_adapter)),
      storage_adapter:
        Keyword.get(opts, :storage_adapter, Keyword.get(config, :storage_adapter, :memory)),
      session_coordinator_enabled:
        Keyword.get(
          opts,
          :session_coordinator_enabled,
          Keyword.get(coordinator_config, :enabled, true)
        ),
      session_coordinator_name: Keyword.get(opts, :session_coordinator_name, SessionCoordinator),
      session_rebuild_retry_enabled:
        Keyword.get(
          opts,
          :session_rebuild_retry_enabled,
          Keyword.get(config, :session_rebuild_retry_enabled, true)
        ),
      event_coordination_enabled:
        Keyword.get(
          opts,
          :event_coordination_enabled,
          Keyword.get(config, :event_coordination_enabled, true)
        ),
      wake_enabled: Keyword.get(opts, :wake_enabled, Keyword.get(config, :wake_enabled, true)),
      ops_policy_provider:
        Keyword.get(
          opts,
          :ops_policy_provider,
          Keyword.get(config, :ops_policy_provider, OpsPolicyProvider)
        ),
      ops_policy_identity:
        opts
        |> Keyword.get(
          :ops_policy_identity,
          Keyword.get(config, :ops_policy_identity, %{
            tenant: "default",
            env: "prod",
            scope: "gateway"
          })
        )
        |> normalize_overrides(),
      inbox_store_opts:
        Keyword.get(opts, :inbox_store_opts, Keyword.get(config, :inbox_store_opts, [])),
      repl_store_opts:
        Keyword.get(
          opts,
          :repl_store_opts,
          Keyword.get(config, :repl_store_opts, Keyword.get(opts, :inbox_store_opts, []))
        ),
      rebuild_target: Keyword.get(opts, :rebuild_target, Keyword.get(config, :rebuild_target)),
      rebuild_notify_pid:
        Keyword.get(opts, :rebuild_notify_pid, Keyword.get(config, :rebuild_notify_pid)),
      mode_state_machine_enabled:
        Keyword.get(
          opts,
          :mode_state_machine_enabled,
          Keyword.get(config, :mode_state_machine_enabled, true)
        ),
      mode_policy_apply:
        Keyword.get(opts, :mode_policy_apply, Keyword.get(config, :mode_policy_apply, false)),
      mode_state_machine:
        Keyword.get(
          opts,
          :mode_state_machine,
          Keyword.get(config, :mode_state_machine, ModeStateMachine)
        ),
      mode_state_machine_mode:
        Keyword.get(
          opts,
          :mode_state_machine_mode,
          Keyword.get(config, :mode_state_machine_mode, :research)
        ),
      mode_state_machine_context:
        Keyword.get(
          opts,
          :mode_state_machine_context,
          Keyword.get(config, :mode_state_machine_context, ModeStateMachine.initial_context())
        ),
      mode_state_machine_options:
        opts
        |> Keyword.get(
          :mode_state_machine_options,
          Keyword.get(config, :mode_state_machine_options, %{})
        )
        |> normalize_overrides(),
      mode_transition_topic:
        Keyword.get(
          opts,
          :mode_transition_topic,
          Keyword.get(config, :mode_transition_topic, "mode_transitions")
        ),
      mode_transition_suppression_window_ticks:
        Keyword.get(
          opts,
          :mode_transition_suppression_window_ticks,
          Keyword.get(config, :mode_transition_suppression_window_ticks, 8)
        ),
      mode_transition_suppression_limit:
        Keyword.get(
          opts,
          :mode_transition_suppression_limit,
          Keyword.get(config, :mode_transition_suppression_limit, 4)
        ),
      mode_transition_recovery_ticks:
        Keyword.get(
          opts,
          :mode_transition_recovery_ticks,
          Keyword.get(config, :mode_transition_recovery_ticks, 6)
        ),
      runtime_adapter:
        Keyword.get(opts, :runtime_adapter, Keyword.get(config, :runtime_adapter, Adapter)),
      jit_feature_flag:
        Keyword.get(opts, :jit_feature_flag, Keyword.get(config, :jit_feature_flag, :jit_enabled)),
      run_terminal_limit:
        Keyword.get(opts, :run_terminal_limit, Keyword.get(config, :run_terminal_limit, 1_000)),
      run_terminal_order: :queue.new(),
      session_last_context: %{},
      run_terminal_results: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:dispatch, inbound_event}, _from, state) do
    {reply, new_state} = run_dispatch(state, inbound_event)
    {:reply, reply, new_state}
  end

  def handle_call({:coordinate_event, inbound_event, runtime_overrides}, _from, state) do
    {:reply, run_event_coordination(state, inbound_event, runtime_overrides), state}
  end

  @impl true
  def handle_cast({:enqueue, inbound_event}, state) do
    {_reply, new_state} = run_dispatch(state, inbound_event)
    {:noreply, new_state}
  end

  defp run_event_coordination(state, inbound_event, runtime_overrides) do
    with {:ok, envelope} <- EventEnvelope.normalize(inbound_event),
         {:ok, policy} <- load_runtime_policy(state, runtime_overrides),
         :ok <- emit_event_ingested_log(envelope, policy),
         {:ok, decided_envelope, decision} <- WakePolicy.decide(envelope, policy),
         :ok <- emit_wake_decision_log(decided_envelope, decision),
         {:ok, store_result} <-
           ReplStore.put_inbox(
             decided_envelope,
             policy,
             Keyword.merge(
               state.repl_store_opts,
               actor: actor_from_envelope(decided_envelope)
             )
           ) do
      rebuild_triggered = maybe_trigger_rebuild(state, store_result.status, decided_envelope)

      {:ok,
       %{
         envelope: decided_envelope,
         store_result: normalize_store_result(store_result.status),
         rebuild_triggered: rebuild_triggered
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_runtime_policy(state, runtime_overrides) do
    overrides = normalize_overrides(runtime_overrides)

    identity =
      state.ops_policy_identity
      |> Map.merge(Map.get(overrides, :ops_policy_identity, %{}))

    with {:ok, policy} <- state.ops_policy_provider.get_policy(identity: identity) do
      if state.event_coordination_enabled do
        {:ok, policy}
      else
        {:ok, disable_wake_policy(policy)}
      end
    end
  end

  defp disable_wake_policy(policy) do
    wake = %{
      "must_wake" => [],
      "inbox_only" => [
        "agent_result",
        "agent_error",
        "policy_changed",
        "heartbeat",
        "tool_progress",
        "telemetry",
        "mode_backfill"
      ]
    }

    Map.put(policy, :wake, wake)
  end

  defp emit_event_ingested_log(envelope, policy) do
    log_payload("event_ingested", %{
      event_id: envelope.event_id,
      session_key: envelope.session_key,
      type: envelope.type,
      source: envelope.source,
      wake: envelope.wake,
      inbox_only: envelope.inbox_only,
      decision_reason: nil,
      policy_version: policy.policy_version
    })
  end

  defp emit_wake_decision_log(envelope, decision) do
    log_payload("wake_decision", %{
      event_id: envelope.event_id,
      session_key: envelope.session_key,
      type: envelope.type,
      source: envelope.source,
      wake: decision.wake,
      inbox_only: decision.inbox_only,
      decision_reason: decision.decision_reason,
      policy_version: decision.policy_version
    })
  end

  # 触发条件必须同时满足：入库成功 + wake=true + inbox_only=false + 功能开关开启。
  defp maybe_trigger_rebuild(state, :stored, envelope) do
    enabled? =
      state.event_coordination_enabled and
        state.wake_enabled and
        envelope.wake == true and
        envelope.inbox_only == false

    if enabled? do
      case do_trigger_rebuild(state, envelope) do
        :ok ->
          emit_telemetry([:dispatch, :rebuild_triggered], %{
            event_id: envelope.event_id,
            type: envelope.type
          })

          true

        {:error, reason} ->
          emit_telemetry([:dispatch, :rebuild_skipped], %{
            event_id: envelope.event_id,
            type: envelope.type,
            store_result: :stored,
            wake: envelope.wake,
            inbox_only: envelope.inbox_only,
            event_coordination_enabled: state.event_coordination_enabled,
            wake_enabled: state.wake_enabled,
            trigger_error: inspect(reason)
          })

          false
      end
    else
      emit_telemetry([:dispatch, :rebuild_skipped], %{
        event_id: envelope.event_id,
        type: envelope.type,
        store_result: :stored,
        wake: envelope.wake,
        inbox_only: envelope.inbox_only,
        event_coordination_enabled: state.event_coordination_enabled,
        wake_enabled: state.wake_enabled
      })

      false
    end
  end

  defp maybe_trigger_rebuild(state, store_result, envelope) do
    emit_telemetry([:dispatch, :rebuild_skipped], %{
      event_id: envelope.event_id,
      type: envelope.type,
      store_result: store_result,
      wake: envelope.wake,
      inbox_only: envelope.inbox_only,
      event_coordination_enabled: state.event_coordination_enabled,
      wake_enabled: state.wake_enabled
    })

    false
  end

  defp do_trigger_rebuild(state, envelope) do
    if is_pid(state.rebuild_notify_pid) do
      send(state.rebuild_notify_pid, {:frame_rebuild_triggered, envelope})
    end

    if not is_nil(state.rebuild_target) do
      GenServer.cast(state.rebuild_target, {:rebuild_frame, envelope})
    end

    :ok
  rescue
    error ->
      Logger.warning("gateway.dispatch rebuild trigger failed error=#{inspect(error)}")
      {:error, {:exception, error}}
  catch
    kind, reason ->
      Logger.warning(
        "gateway.dispatch rebuild trigger failed kind=#{inspect(kind)} reason=#{inspect(reason)}"
      )

      {:error, {kind, reason}}
  end

  defp emit_telemetry(path, metadata) when is_list(path) and is_map(metadata) do
    :telemetry.execute([:men, :gateway | path], %{count: 1}, metadata)
    :ok
  rescue
    _ -> :ok
  end

  defp normalize_overrides(overrides) when is_list(overrides), do: Map.new(overrides)
  defp normalize_overrides(overrides) when is_map(overrides), do: overrides
  defp normalize_overrides(_), do: %{}

  defp actor_from_envelope(envelope) do
    source = envelope.source || ""

    cond do
      source == "mode_state_machine" ->
        %{role: :system, session_key: envelope.session_key}

      String.starts_with?(source, "agent.") or String.starts_with?(source, "child.") ->
        [_, agent_id] = String.split(source, ".", parts: 2)
        %{role: :child, agent_id: agent_id, session_key: envelope.session_key}

      String.starts_with?(source, "tool.") ->
        [_, tool_id | _] = String.split(source, ".")

        %{
          role: :tool,
          tool_id: tool_id,
          agent_id: Map.get(envelope.meta, :agent_id),
          session_key: envelope.session_key
        }

      true ->
        %{role: :unknown, session_key: envelope.session_key}
    end
  end

  defp normalize_store_result(:stored), do: :ok
  defp normalize_store_result(:duplicate), do: :duplicate
  defp normalize_store_result(:idempotent), do: :duplicate
  defp normalize_store_result(:older_drop), do: :stale

  defp log_payload(event_name, payload) do
    Logger.info("#{event_name} #{Jason.encode!(payload)}")
    :ok
  rescue
    _ -> :ok
  end

  # 每轮调度先做模式状态机决策，再进入 runtime bridge。
  defp maybe_run_mode_state_machine(%{mode_state_machine_enabled: false} = state, _inbound_event),
    do: state

  defp maybe_run_mode_state_machine(state, inbound_event) do
    snapshot = extract_mode_snapshot(inbound_event)

    machine_overrides =
      state.mode_state_machine_options
      |> Map.put_new(:churn_window_ticks, state.mode_transition_suppression_window_ticks)
      |> Map.put_new(:churn_max_transitions, state.mode_transition_suppression_limit)
      |> Map.put_new(:research_only_recovery_ticks, state.mode_transition_recovery_ticks)
      |> Map.put_new(:apply_mode?, state.mode_policy_apply)

    {next_mode, next_context, decision_meta} =
      state.mode_state_machine.decide(
        state.mode_state_machine_mode,
        snapshot,
        state.mode_state_machine_context,
        machine_overrides
      )

    base_state = %{
      state
      | mode_state_machine_mode: next_mode,
        mode_state_machine_context: next_context
    }

    cond do
      decision_meta.transition? ->
        finalize_mode_transition(base_state, snapshot, decision_meta)

      decision_meta.recommended_mode in [:research, :execute] ->
        finalize_mode_advice(base_state, snapshot, decision_meta)

      true ->
        base_state
    end
  end

  defp finalize_mode_advice(state, snapshot, decision_meta) do
    advice_event = %{
      recommendation_id: new_transition_id(),
      from_mode: decision_meta.from_mode,
      recommended_mode: decision_meta.recommended_mode,
      reason: decision_meta.reason,
      priority: decision_meta.priority,
      tick: decision_meta.tick,
      snapshot_digest: snapshot_digest(snapshot),
      hysteresis_state: decision_meta.hysteresis_state,
      apply_mode?: decision_meta.apply_mode?
    }

    publish_mode_transition(state.mode_transition_topic, advice_event)

    if is_pid(state.rebuild_notify_pid) do
      send(state.rebuild_notify_pid, {:mode_advised, advice_event})
    end

    state
  end

  defp finalize_mode_transition(state, snapshot, decision_meta) do
    transition_id = new_transition_id()
    backfill_tasks = maybe_build_backfill_tasks(snapshot, decision_meta, transition_id)

    inserted_backfill_tasks = dedup_backfill_tasks(backfill_tasks)

    queued_backfill_tasks =
      enqueue_backfill_tasks(inserted_backfill_tasks, state.inbox_store_opts)

    transition_event = %{
      transition_id: transition_id,
      from_mode: decision_meta.from_mode,
      to_mode: decision_meta.to_mode,
      reason: decision_meta.reason,
      priority: decision_meta.priority,
      tick: decision_meta.tick,
      snapshot_digest: snapshot_digest(snapshot),
      hysteresis_state: decision_meta.hysteresis_state,
      cooldown_remaining: decision_meta.cooldown_remaining,
      inserted_backfill_tasks: queued_backfill_tasks
    }

    publish_mode_transition(state.mode_transition_topic, transition_event)

    if is_pid(state.rebuild_notify_pid) do
      send(state.rebuild_notify_pid, {:mode_transitioned, transition_event})
    end

    state
  end

  # execute 回退 research 时只针对失效前提相关关键路径补链。
  defp maybe_build_backfill_tasks(
         snapshot,
         %{from_mode: :execute, to_mode: :research} = meta,
         transition_id
       ) do
    reason = meta.reason

    if reason in [:premise_invalidated, :external_mutation, :info_insufficient] do
      premise_ids =
        snapshot
        |> Map.get(:invalidated_premise_ids, [])
        |> List.wrap()
        |> Enum.filter(&is_binary/1)

      critical_paths_by_premise =
        snapshot
        |> Map.get(:critical_paths_by_premise, %{})
        |> normalize_overrides()

      Enum.flat_map(premise_ids, fn premise_id ->
        critical_paths = Map.get(critical_paths_by_premise, premise_id, [])

        if critical_paths == [] do
          [%{transition_id: transition_id, premise_id: premise_id, critical_path: nil}]
        else
          Enum.map(critical_paths, fn path_id ->
            %{
              transition_id: transition_id,
              premise_id: premise_id,
              critical_path: path_id
            }
          end)
        end
      end)
    else
      []
    end
  end

  defp maybe_build_backfill_tasks(_snapshot, _meta, _transition_id), do: []

  # 在单次迁移内按 {transition_id, premise_id, critical_path} 去重，
  # 既消除重复 premise 输入，又保留同一 premise 的多关键路径补链。
  defp dedup_backfill_tasks(tasks) do
    Enum.reduce(tasks, {[], MapSet.new()}, fn task, {acc, keys} ->
      dedup_key = {task.transition_id, task.premise_id, task.critical_path}

      if MapSet.member?(keys, dedup_key) do
        {acc, keys}
      else
        {[task | acc], MapSet.put(keys, dedup_key)}
      end
    end)
    |> then(fn {inserted, _keys} -> Enum.reverse(inserted) end)
  end

  defp enqueue_backfill_tasks(tasks, inbox_store_opts) do
    Enum.reduce(tasks, [], fn task, acc ->
      envelope = build_backfill_envelope(task)

      case InboxStore.put(envelope, inbox_store_opts) do
        {:ok, _} ->
          [task | acc]

        {:duplicate, _} ->
          acc

        {:stale, _} ->
          acc

        {:error, reason} ->
          Logger.warning(
            "mode backfill enqueue failed transition_id=#{task.transition_id} " <>
              "premise_id=#{task.premise_id} reason=#{inspect(reason)}"
          )

          acc
      end
    end)
    |> Enum.reverse()
  end

  defp build_backfill_envelope(task) do
    critical_path_key = backfill_critical_path_key(task.critical_path)

    %EventEnvelope{
      type: "mode_backfill",
      source: "mode_state_machine",
      target: "runtime",
      session_key: "mode_state_machine",
      event_id: "#{task.transition_id}:#{task.premise_id}:#{critical_path_key}",
      version: 0,
      wake: false,
      inbox_only: true,
      ets_keys: ["mode_backfill", task.transition_id, task.premise_id, critical_path_key],
      payload: task,
      ts: System.system_time(:millisecond),
      meta: %{transition_id: task.transition_id, premise_id: task.premise_id}
    }
  end

  defp backfill_critical_path_key(nil), do: "__none__"
  defp backfill_critical_path_key(path_id) when is_binary(path_id), do: path_id
  defp backfill_critical_path_key(path_id), do: inspect(path_id)

  defp publish_mode_transition(topic, transition_event) do
    Phoenix.PubSub.broadcast(Men.PubSub, topic, {:mode_transitioned, transition_event})
  rescue
    error ->
      Logger.warning("mode transition publish failed error=#{inspect(error)}")
      :ok
  end

  defp extract_mode_snapshot(%{} = inbound_event) do
    inbound_event
    |> Map.get(:mode_signals, %{})
    |> normalize_overrides()
  end

  defp extract_mode_snapshot(_), do: %{}

  defp snapshot_digest(snapshot) do
    snapshot
    |> :erlang.phash2()
    |> Integer.to_string()
  end

  defp new_transition_id do
    "mode-transition-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp run_dispatch(state, inbound_event) do
    with {:ok, context} <- normalize_event(inbound_event) do
      case CutoverPolicy.route(inbound_event) do
        :ignore ->
          log_transition(:run_ignored, context, default_run_context(context), %{
            reason: :mention_required
          })

          {{:ok, ignored_dispatch_result(context)}, state}

        _ ->
          state = maybe_run_mode_state_machine(state, inbound_event)

          case fetch_terminal_result(state, context.run_id) do
            {:ok, cached_reply} ->
              {cached_reply, state}

            :not_found ->
              execute_dispatch(state, context)
          end
      end
    else
      {:error, reason} ->
        synthetic_context = fallback_context(inbound_event)

        error_payload = %{
          type: :failed,
          code: "INVALID_EVENT",
          message: "invalid inbound event",
          details: %{reason: inspect(reason)}
        }

        error_payload = ensure_error_egress_result(state, synthetic_context, error_payload)
        error_result = build_error_result(synthetic_context, error_payload)
        log_failed(synthetic_context, default_run_context(synthetic_context), error_payload)
        {{:error, error_result}, state}
    end
  end

  defp execute_dispatch(state, context) do
    log_started(context)

    case do_start_turn(state, context) do
      {:ok, bridge_payload, run_context} ->
        case do_send_final(state, context, run_context, bridge_payload) do
          :ok ->
            dispatch_result = build_dispatch_result(context, bridge_payload)
            reply = {:ok, dispatch_result}
            new_state = mark_terminal(state, context, run_context, reply)
            log_transition(:run_completed, context, run_context)
            {reply, new_state}

          {:error, reason} ->
            error_payload = %{
              type: :failed,
              code: "EGRESS_ERROR",
              message: "egress send failed",
              details: %{reason: inspect(reason)}
            }

            error_payload = ensure_error_egress_result(state, context, error_payload)
            error_result = build_error_result(context, error_payload)
            reply = {:error, error_result}
            new_state = maybe_mark_terminal(state, context, run_context, reply, error_payload)
            log_failed(context, run_context, error_payload)
            {reply, new_state}
        end

      {:bridge_error, error_payload, run_context} ->
        error_payload = ensure_error_egress_result(state, context, error_payload)
        error_result = build_error_result(context, error_payload)
        reply = {:error, error_result}
        new_state = maybe_mark_terminal(state, context, run_context, reply, error_payload)
        log_failed(context, run_context, error_payload)
        {reply, new_state}
    end
  end

  # 错误回写失败时统一抬升为 egress 失败，避免调用方误判。
  defp ensure_error_egress_result(state, context, error_payload) do
    case do_send_error(state, context, error_payload) do
      :ok ->
        error_payload

      {:error, reason} ->
        %{
          type: :failed,
          code: "EGRESS_ERROR",
          message: "egress send failed",
          details: %{reason: inspect(reason)}
        }
    end
  end

  defp normalize_event(%{} = inbound_event) do
    with {:ok, request_id} <- fetch_required_binary(inbound_event, :request_id),
         {:ok, payload} <- fetch_required_payload(inbound_event, :payload),
         {:ok, metadata} <- normalize_metadata(Map.get(inbound_event, :metadata)),
         {:ok, session_key} <- resolve_session_key(inbound_event),
         {:ok, run_id} <- resolve_run_id(inbound_event) do
      {:ok,
       %{
         request_id: request_id,
         payload: payload,
         channel: Map.get(inbound_event, :channel),
         metadata: metadata,
         mode_signals:
           inbound_event
           |> Map.get(:mode_signals, %{})
           |> normalize_overrides(),
         session_key: session_key,
         run_id: run_id
       }}
    end
  end

  defp normalize_event(_), do: {:error, :invalid_event}

  defp resolve_session_key(%{session_key: session_key})
       when is_binary(session_key) and session_key != "",
       do: {:ok, session_key}

  defp resolve_session_key(attrs) do
    SessionKey.build(%{
      channel: Map.get(attrs, :channel),
      user_id: Map.get(attrs, :user_id),
      group_id: Map.get(attrs, :group_id),
      thread_id: Map.get(attrs, :thread_id)
    })
  end

  defp resolve_run_id(%{run_id: run_id}) when is_binary(run_id) and run_id != "",
    do: {:ok, run_id}

  defp resolve_run_id(_), do: {:ok, generate_run_id()}

  defp generate_run_id do
    "run-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp fetch_required_binary(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_required_payload(attrs, key) do
    if Map.has_key?(attrs, key),
      do: {:ok, Map.get(attrs, key)},
      else: {:error, {:missing_field, key}}
  end

  defp normalize_metadata(nil), do: {:ok, %{}}
  defp normalize_metadata(%{} = metadata), do: {:ok, metadata}
  defp normalize_metadata(_), do: {:error, {:invalid_field, :metadata}}

  # 将 payload 转为 runtime 可消费的字符串 prompt。
  defp payload_to_prompt(payload) when is_binary(payload), do: {:ok, payload}

  defp payload_to_prompt(payload) do
    case Jason.encode(payload) do
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, {:invalid_payload, reason}}
    end
  end

  defp do_start_turn(state, context) do
    with {:ok, prompt} <- payload_to_prompt(context.payload),
         {:ok, run_context} <-
           resolve_runtime_context(state, context.session_key, context.run_id, 1),
         {:ok, run_context} <- enrich_runtime_context(state, context, run_context) do
      case call_bridge(state, prompt, context, run_context) do
        {:ok, payload} ->
          {:ok, payload, run_context}

        {:error, error_payload} ->
          maybe_retry_start_turn(state, context, prompt, run_context, error_payload)
      end
    else
      {:error, {:invalid_payload, reason}} ->
        {:bridge_error,
         %{
           type: :failed,
           code: "INVALID_PAYLOAD",
           message: "payload encode failed",
           details: %{reason: inspect(reason)}
         }, default_run_context(context)}

      {:error, _reason} ->
        {:bridge_error,
         %{
           type: :failed,
           code: "SESSION_RESOLVE_FAILED",
           message: "runtime session resolve failed",
           details: %{}
         }, default_run_context(context)}
    end
  end

  defp maybe_retry_start_turn(state, context, prompt, run_context, error_payload) do
    if should_retry_session_not_found?(state, run_context, error_payload) do
      log_transition(:retry_triggered, context, run_context, %{
        code: Map.get(error_payload, :code)
      })

      case rebuild_runtime_context(state, context.session_key, context.run_id, 2) do
        {:ok, retry_context} ->
          case call_bridge(state, prompt, context, retry_context) do
            {:ok, payload} -> {:ok, payload, retry_context}
            {:error, retry_error_payload} -> {:bridge_error, retry_error_payload, retry_context}
          end

        {:error, _reason} ->
          {:bridge_error, error_payload, run_context}
      end
    else
      {:bridge_error, error_payload, run_context}
    end
  end

  defp resolve_runtime_context(
         %{session_coordinator_enabled: false},
         session_key,
         run_id,
         attempt
       ) do
    {:ok,
     %{
       run_id: run_id,
       session_key: session_key,
       runtime_session_id: session_key,
       attempt: attempt
     }}
  end

  defp resolve_runtime_context(state, session_key, run_id, attempt) do
    runtime_session_id =
      case safe_get_or_create_runtime_session_id(state.session_coordinator_name, session_key) do
        {:ok, resolved_runtime_session_id} -> resolved_runtime_session_id
        {:error, _reason} -> session_key
      end

    run_context = %{
      run_id: run_id,
      session_key: session_key,
      runtime_session_id: runtime_session_id,
      attempt: attempt
    }

    log_transition(:session_resolved, %{run_id: run_id, session_key: session_key}, run_context)
    {:ok, run_context}
  end

  defp rebuild_runtime_context(
         %{session_coordinator_enabled: false},
         session_key,
         run_id,
         attempt
       ) do
    {:ok,
     %{
       run_id: run_id,
       session_key: session_key,
       runtime_session_id: session_key,
       attempt: attempt
     }}
  end

  defp rebuild_runtime_context(state, session_key, run_id, attempt) do
    case safe_rebuild_runtime_session_id(state.session_coordinator_name, session_key) do
      {:ok, runtime_session_id} ->
        run_context = %{
          run_id: run_id,
          session_key: session_key,
          runtime_session_id: runtime_session_id,
          attempt: attempt
        }

        log_transition(
          :session_resolved,
          %{run_id: run_id, session_key: session_key},
          run_context
        )

        {:ok, run_context}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # coordinator 可能在调用窗口重启，捕获 exit 以保证 dispatch 可降级。
  defp safe_get_or_create_runtime_session_id(coordinator_name, session_key) do
    try do
      SessionCoordinator.get_or_create_session(coordinator_name, session_key)
    catch
      :exit, _reason -> {:error, :session_coordinator_unavailable}
    end
  end

  # 重建属于受控自愈，coordinator 不可用时维持原错误返回。
  defp safe_rebuild_runtime_session_id(coordinator_name, session_key) do
    try do
      SessionCoordinator.rebuild_session(coordinator_name, session_key)
    catch
      :exit, _reason -> {:error, :session_coordinator_unavailable}
    end
  end

  defp call_bridge(state, prompt, context, run_context) do
    bridge_context = %{
      request_id: context.request_id,
      session_key: run_context.runtime_session_id,
      external_session_key: context.session_key,
      run_id: context.run_id
    }

    case dispatch_route(state, context) do
      :legacy ->
        (state.legacy_bridge_adapter || state.bridge_adapter).start_turn(prompt, bridge_context)

      :zcpg ->
        case state.zcpg_client.start_turn(prompt, bridge_context) do
          {:ok, payload} ->
            {:ok, put_dispatch_route(payload, :zcpg)}

          {:error, error_payload} ->
            if Map.get(error_payload, :fallback, false) do
              case (state.legacy_bridge_adapter || state.bridge_adapter).start_turn(
                     prompt,
                     bridge_context
                   ) do
                {:ok, payload} -> {:ok, put_dispatch_route(payload, :legacy_fallback)}
                {:error, legacy_error_payload} -> {:error, legacy_error_payload}
              end
            else
              {:error, error_payload}
            end
        end
    end
  end

  defp dispatch_route(%{legacy_bridge_adapter: nil, zcpg_client: nil}, _context), do: :legacy

  defp dispatch_route(state, context) do
    event = %{
      channel: context.channel,
      payload: context.payload,
      metadata: context.metadata
    }

    cutover_config = Application.get_env(:men, :zcpg_cutover, state.zcpg_cutover_config)

    case CutoverPolicy.route(event, config: cutover_config) do
      :zcpg when not is_nil(state.zcpg_client) -> :zcpg
      _ -> :legacy
    end
  end

  defp put_dispatch_route(%{meta: meta} = payload, route) when is_map(meta) do
    %{payload | meta: Map.put(meta, :dispatch_route, route)}
  end

  defp put_dispatch_route(%{} = payload, route), do: Map.put(payload, :meta, %{dispatch_route: route})
  defp put_dispatch_route(payload, _route), do: payload

  # 在主链路内执行 JIT 运行时决策，并将结果附加到 run_context（供 egress metadata 使用）。
  defp enrich_runtime_context(state, context, run_context) do
    runtime_state = build_runtime_state(context)

    adapter_opts = [
      trace_id: context.request_id,
      session_id: context.session_key,
      jit_flag: state.jit_feature_flag,
      current_mode: state.mode_state_machine_mode,
      mode_context: state.mode_state_machine_context,
      mode_policy_apply: state.mode_policy_apply,
      mode_state_machine_options: state.mode_state_machine_options,
      mode_signals: Map.get(context, :mode_signals, %{})
    ]

    case state.runtime_adapter.orchestrate(runtime_state, adapter_opts) do
      {:ok, jit_result} ->
        {:ok, Map.put(run_context, :jit_result, jit_result)}

      {:error, reason} ->
        Logger.warning(
          "gateway.dispatch jit enrich failed run_id=#{context.run_id} reason=#{inspect(reason)}"
        )

        {:ok, run_context}
    end
  end

  defp build_runtime_state(context) do
    payload_map =
      case context.payload do
        %{} = payload -> payload
        _ -> %{}
      end

    %{
      goal: Map.get(payload_map, :goal) || Map.get(payload_map, "goal"),
      policy: Map.get(payload_map, :policy) || Map.get(payload_map, "policy"),
      current_focus:
        Map.get(payload_map, :current_focus) || Map.get(payload_map, "current_focus"),
      next_candidates:
        Map.get(payload_map, :next_candidates) || Map.get(payload_map, "next_candidates") || [],
      constraints:
        Map.get(payload_map, :constraints) || Map.get(payload_map, "constraints") || [],
      recommendations:
        Map.get(payload_map, :recommendations) || Map.get(payload_map, "recommendations") || [],
      research_state:
        Map.get(payload_map, :research_state) || Map.get(payload_map, "research_state") || %{},
      research_events:
        Map.get(payload_map, :research_events) || Map.get(payload_map, "research_events") || [],
      execute_tasks:
        Map.get(payload_map, :execute_tasks) || Map.get(payload_map, "execute_tasks") || [],
      execute_edges:
        Map.get(payload_map, :execute_edges) || Map.get(payload_map, "execute_edges") || [],
      key_claim_confidence:
        Map.get(payload_map, :key_claim_confidence) ||
          Map.get(payload_map, "key_claim_confidence") || 0.0,
      graph_change_rate:
        Map.get(payload_map, :graph_change_rate) || Map.get(payload_map, "graph_change_rate") ||
          1.0
    }
  end

  defp should_retry_session_not_found?(state, run_context, error_payload) do
    state.session_rebuild_retry_enabled and
      run_context.attempt == 1 and
      retryable_session_not_found_code?(Map.get(error_payload, :code))
  end

  defp retryable_session_not_found_code?(code) do
    normalized_code = normalize_error_code(code)
    normalized_code == "session_not_found"
  end

  defp normalize_error_code(code) when is_atom(code),
    do: code |> Atom.to_string() |> String.downcase()

  defp normalize_error_code(code) when is_binary(code),
    do: code |> String.trim() |> String.downcase()

  defp normalize_error_code(_), do: ""

  defp do_send_final(state, context, run_context, bridge_payload) do
    jit_meta = build_jit_metadata(run_context)

    metadata =
      context.metadata
      |> Map.merge(Map.get(bridge_payload, :meta, %{}))
      |> Map.merge(jit_meta)
      |> Map.merge(%{
        request_id: context.request_id,
        run_id: context.run_id,
        session_key: context.session_key
      })

    message = %FinalMessage{
      session_key: context.session_key,
      content: Map.get(bridge_payload, :text, ""),
      metadata: metadata
    }

    state.egress_adapter.send(context.session_key, message)
  end

  defp build_jit_metadata(%{jit_result: jit_result}) when is_map(jit_result) do
    %{
      jit_flag_state: Map.get(jit_result, :flag_state),
      jit_advisor_decision: Map.get(jit_result, :advisor_decision),
      jit_snapshot_action: Map.get(jit_result, :snapshot_action),
      jit_rollback_reason: Map.get(jit_result, :rollback_reason),
      jit_degraded: Map.get(jit_result, :degraded?, false)
    }
  end

  defp build_jit_metadata(_context), do: %{}

  defp do_send_error(state, context, error_payload) do
    message = %ErrorMessage{
      session_key: context.session_key,
      reason: Map.get(error_payload, :message, "dispatch failed"),
      code: Map.get(error_payload, :code),
      metadata:
        context.metadata
        |> Map.merge(%{
          request_id: context.request_id,
          run_id: context.run_id,
          session_key: context.session_key,
          type: Map.get(error_payload, :type),
          details: Map.get(error_payload, :details)
        })
    }

    state.egress_adapter.send(context.session_key, message)
  end

  defp fetch_terminal_result(state, run_id) do
    case Map.fetch(state.run_terminal_results, run_id) do
      {:ok, cached_reply} -> {:ok, cached_reply}
      :error -> :not_found
    end
  end

  defp mark_terminal(state, context, run_context, reply) do
    next_state = put_terminal_result(state, context.run_id, reply)

    %{
      next_state
      | session_last_context:
          Map.put(state.session_last_context, context.session_key, run_context),
        run_terminal_results: next_state.run_terminal_results,
        run_terminal_order: next_state.run_terminal_order
    }
  end

  defp put_terminal_result(state, run_id, reply) do
    if Map.has_key?(state.run_terminal_results, run_id) do
      %{state | run_terminal_results: Map.put(state.run_terminal_results, run_id, reply)}
    else
      state
      |> Map.update!(:run_terminal_results, &Map.put(&1, run_id, reply))
      |> Map.update!(:run_terminal_order, &:queue.in(run_id, &1))
      |> evict_terminal_results()
    end
  end

  # 终态缓存为幂等兜底，不追求永久保留；采用 FIFO 控制内存上界。
  defp evict_terminal_results(state) do
    if map_size(state.run_terminal_results) <= state.run_terminal_limit do
      state
    else
      case :queue.out(state.run_terminal_order) do
        {{:value, oldest_run_id}, next_order} ->
          state
          |> Map.put(:run_terminal_order, next_order)
          |> Map.update!(:run_terminal_results, &Map.delete(&1, oldest_run_id))
          |> evict_terminal_results()

        {:empty, _queue} ->
          state
      end
    end
  end

  # egress 失败时不记录已处理，允许同 run_id 做恢复性重试。
  defp maybe_mark_terminal(state, _context, _run_context, _reply, %{code: "EGRESS_ERROR"}),
    do: state

  defp maybe_mark_terminal(state, context, run_context, reply, _error_payload),
    do: mark_terminal(state, context, run_context, reply)

  defp build_dispatch_result(context, bridge_payload) do
    %{
      session_key: context.session_key,
      run_id: context.run_id,
      request_id: context.request_id,
      payload: bridge_payload,
      metadata: context.metadata
    }
  end

  defp ignored_dispatch_result(context) do
    %{
      session_key: context.session_key,
      run_id: context.run_id,
      request_id: context.request_id,
      payload: %{text: "", meta: %{ignored: true, reason: "mention_required"}},
      metadata: Map.put(context.metadata, :ignored, true)
    }
  end

  defp build_error_result(context, error_payload) do
    %{
      session_key: context.session_key,
      run_id: context.run_id,
      request_id: context.request_id,
      reason: Map.get(error_payload, :message, "dispatch failed"),
      code: Map.get(error_payload, :code),
      metadata:
        context.metadata
        |> Map.merge(%{
          type: Map.get(error_payload, :type),
          details: Map.get(error_payload, :details)
        })
    }
  end

  defp log_started(context) do
    log_transition(:run_started, context, default_run_context(context))
  end

  defp log_failed(context, run_context, error_payload) do
    log_transition(:run_failed, context, run_context, %{code: Map.get(error_payload, :code)})
  end

  # 状态流转使用统一日志格式，便于按 run/session 追踪。
  defp log_transition(event, context, run_context, extra \\ %{}) do
    Logger.info(
      "gateway.dispatch event=#{event} run_id=#{context.run_id} session_key=#{context.session_key} " <>
        "runtime_session_id=#{run_context.runtime_session_id} attempt=#{run_context.attempt} " <>
        "extra=#{inspect(extra)}"
    )
  end

  defp default_run_context(context) do
    %{
      run_id: context.run_id,
      session_key: context.session_key,
      runtime_session_id: context.session_key,
      attempt: 1
    }
  end

  defp fallback_context(%{} = inbound_event) do
    %{
      session_key: Map.get(inbound_event, :session_key, "unknown_session"),
      run_id: Map.get(inbound_event, :run_id, "unknown_run"),
      request_id: Map.get(inbound_event, :request_id, "unknown_request"),
      payload: Map.get(inbound_event, :payload),
      metadata: %{}
    }
  end

  defp fallback_context(_inbound_event) do
    %{
      session_key: "unknown_session",
      run_id: "unknown_run",
      request_id: "unknown_request",
      payload: nil,
      metadata: %{}
    }
  end
end
