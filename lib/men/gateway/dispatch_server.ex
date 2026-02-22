defmodule Men.Gateway.DispatchServer do
  @moduledoc """
  L1 主状态机：串联 inbound -> runtime bridge -> egress。
  """

  use GenServer

  require Logger

  alias Men.Channels.Egress.Messages.{ErrorMessage, FinalMessage}
  alias Men.Gateway.EventEnvelope
  alias Men.Gateway.InboxStore
  alias Men.Gateway.SessionCoordinator
  alias Men.Gateway.Types
  alias Men.Gateway.WakePolicy
  alias Men.Routing.SessionKey

  @type terminal_reply :: {:ok, Types.dispatch_result()} | {:error, Types.error_result()}

  @type state :: %{
          bridge_adapter: module(),
          egress_adapter: module(),
          storage_adapter: term(),
          session_coordinator_enabled: boolean(),
          session_coordinator_name: GenServer.server(),
          session_rebuild_retry_enabled: boolean(),
          event_coordination_enabled: boolean(),
          wake_enabled: boolean(),
          wake_policy_overrides: map(),
          wake_policy_strict_inbox_priority: boolean(),
          inbox_store_opts: keyword(),
          rebuild_target: GenServer.server() | nil,
          rebuild_notify_pid: pid() | nil,
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
      wake_policy_overrides:
        opts
        |> Keyword.get(:wake_policy_overrides, Keyword.get(config, :wake_policy_overrides, %{}))
        |> normalize_overrides(),
      wake_policy_strict_inbox_priority:
        Keyword.get(
          opts,
          :wake_policy_strict_inbox_priority,
          Keyword.get(config, :wake_policy_strict_inbox_priority, true)
        ),
      inbox_store_opts:
        Keyword.get(opts, :inbox_store_opts, Keyword.get(config, :inbox_store_opts, [])),
      rebuild_target: Keyword.get(opts, :rebuild_target, Keyword.get(config, :rebuild_target)),
      rebuild_notify_pid:
        Keyword.get(opts, :rebuild_notify_pid, Keyword.get(config, :rebuild_notify_pid)),
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
         :ok <-
           emit_telemetry([:event, :normalized], %{
             event_id: envelope.event_id,
             type: envelope.type
           }),
         {:ok, decided_envelope, decision} <- decide_policy(state, envelope, runtime_overrides),
         :ok <-
           emit_telemetry([:policy, :decided], %{
             event_id: decided_envelope.event_id,
             type: decided_envelope.type,
             wake: decision.wake,
             inbox_only: decision.inbox_only
           }),
         {:ok, store_tag, store_envelope} <-
           store_inbox(decided_envelope, state.inbox_store_opts),
         :ok <- emit_store_telemetry(store_tag, store_envelope) do
      rebuild_triggered = maybe_trigger_rebuild(state, store_tag, store_envelope)

      {:ok,
       %{
         envelope: store_envelope,
         store_result: store_tag,
         rebuild_triggered: rebuild_triggered
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decide_policy(state, envelope, runtime_overrides) do
    policy_envelope = enforce_disabled_envelope(envelope, state.event_coordination_enabled)

    coordination_overrides =
      runtime_overrides
      |> normalize_overrides()
      |> maybe_force_inbox_only(state.event_coordination_enabled)
      |> Map.put_new(:strict_inbox_priority, state.wake_policy_strict_inbox_priority)

    merged_overrides = Map.merge(state.wake_policy_overrides, coordination_overrides)
    WakePolicy.decide(policy_envelope, merged_overrides)
  end

  defp store_inbox(envelope, inbox_store_opts) do
    case InboxStore.put(envelope, inbox_store_opts) do
      {:ok, accepted} -> {:ok, :ok, accepted}
      {:duplicate, accepted} -> {:ok, :duplicate, accepted}
      {:stale, accepted} -> {:ok, :stale, accepted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_store_telemetry(:ok, _envelope), do: :ok

  defp emit_store_telemetry(:duplicate, envelope) do
    emit_telemetry([:inbox, :duplicate], %{event_id: envelope.event_id, type: envelope.type})
  end

  defp emit_store_telemetry(:stale, envelope) do
    emit_telemetry([:inbox, :stale], %{
      event_id: envelope.event_id,
      type: envelope.type,
      version: envelope.version
    })
  end

  defp emit_store_telemetry(_other, _envelope), do: :ok

  # 触发条件必须同时满足：入库成功 + wake=true + inbox_only=false + 功能开关开启。
  defp maybe_trigger_rebuild(state, :ok, envelope) do
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
            store_result: :ok,
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
        store_result: :ok,
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

  # 关闭总线时强制降级到 inbox_only，保证事件仍可入箱且不触发重建。
  defp enforce_disabled_envelope(envelope, true), do: envelope

  defp enforce_disabled_envelope(envelope, false) do
    %EventEnvelope{envelope | wake: nil, inbox_only: nil, force_wake: false}
  end

  defp maybe_force_inbox_only(overrides, true), do: overrides

  defp maybe_force_inbox_only(overrides, false) do
    overrides
    |> Map.put(:wake, false)
    |> Map.put(:inbox_only, true)
  end

  defp run_dispatch(state, inbound_event) do
    with {:ok, context} <- normalize_event(inbound_event) do
      case fetch_terminal_result(state, context.run_id) do
        {:ok, cached_reply} ->
          {cached_reply, state}

        :not_found ->
          execute_dispatch(state, context)
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
        case do_send_final(state, context, bridge_payload) do
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
         metadata: metadata,
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
           resolve_runtime_context(state, context.session_key, context.run_id, 1) do
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

    state.bridge_adapter.start_turn(prompt, bridge_context)
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

  defp do_send_final(state, context, bridge_payload) do
    metadata =
      context.metadata
      |> Map.merge(Map.get(bridge_payload, :meta, %{}))
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
