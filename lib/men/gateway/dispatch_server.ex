defmodule Men.Gateway.DispatchServer do
  @moduledoc """
  L1 主状态机：串联 inbound -> runtime bridge -> egress。
  """

  use GenServer
  require Logger

  alias Men.Channels.Egress.Messages.{ErrorMessage, EventMessage, FinalMessage}
  alias Men.Gateway.SessionCoordinator
  alias Men.Gateway.Types
  alias Men.Routing.SessionKey

  @type state :: %{
          bridge_adapter: module(),
          egress_adapter: module(),
          storage_adapter: term(),
          streaming_enabled: boolean(),
          session_coordinator_enabled: boolean(),
          session_coordinator_name: GenServer.server(),
          processed_run_ids: MapSet.t(binary()),
          session_last_context: %{optional(binary()) => Types.run_context()}
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
          {:ok, Types.dispatch_result() | :duplicate} | {:error, Types.error_result()}
  def dispatch(server \\ __MODULE__, inbound_event) do
    GenServer.call(server, {:dispatch, inbound_event})
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
      streaming_enabled:
        Keyword.get(
          opts,
          :streaming_enabled,
          Keyword.get(
            config,
            :streaming_enabled,
            Keyword.get(config, :chat_streaming_enabled, false)
          )
        ),
      session_coordinator_enabled:
        Keyword.get(
          opts,
          :session_coordinator_enabled,
          Keyword.get(coordinator_config, :enabled, true)
        ),
      session_coordinator_name: Keyword.get(opts, :session_coordinator_name, SessionCoordinator),
      processed_run_ids: MapSet.new(),
      session_last_context: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:dispatch, inbound_event}, _from, state) do
    {reply, new_state} = run_dispatch(state, inbound_event)
    {:reply, reply, new_state}
  end

  @impl true
  def handle_cast({:enqueue, inbound_event}, state) do
    {_reply, new_state} = run_dispatch(state, inbound_event)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:session_event, event}, state) when is_map(event) do
    # GongRPC 订阅会把完整 session 事件流投递到当前进程。
    # 主链路只消费关键信号，其余事件在这里兜底吞掉，避免 error 噪音。
    Logger.debug("dispatch_server.session_event.ignored", event: summarize_session_event(event))
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    Logger.error(
      "#{inspect(__MODULE__)} received unexpected message in handle_info/2: #{inspect(message)}"
    )

    {:noreply, state}
  end

  defp run_dispatch(state, inbound_event) do
    Logger.info("dispatch_server.run_dispatch.begin", event: summarize_event(inbound_event))

    with {:ok, context} <- normalize_event(inbound_event),
         :ok <- ensure_not_duplicate(context.run_id, state),
         {:ok, bridge_payload} <- do_start_turn(state, context),
         :ok <- do_send_final(state, context, bridge_payload) do
      new_state = mark_processed(state, context)

      Logger.info("dispatch_server.run_dispatch.ok",
        request_id: context.request_id,
        run_id: context.run_id,
        session_key: context.session_key
      )

      {{:ok, build_dispatch_result(context, bridge_payload)}, new_state}
    else
      {:duplicate, run_id} ->
        _ = run_id
        Logger.warning("dispatch_server.run_dispatch.duplicate", run_id: run_id)
        {{:ok, :duplicate}, state}

      {:bridge_error, error_payload, context} ->
        Logger.error("dispatch_server.run_dispatch.bridge_error",
          request_id: context.request_id,
          run_id: context.run_id,
          type: Map.get(error_payload, :type),
          code: Map.get(error_payload, :code),
          message: Map.get(error_payload, :message),
          details: Map.get(error_payload, :details),
          error_payload:
            inspect(error_payload, pretty: true, limit: :infinity, printable_limit: :infinity)
        )

        error_payload = ensure_error_egress_result(state, context, error_payload)
        new_state = maybe_mark_processed(state, context, error_payload)
        {{:error, build_error_result(context, error_payload)}, new_state}

      {:egress_error, reason, context} ->
        Logger.error("dispatch_server.run_dispatch.egress_error",
          request_id: context.request_id,
          run_id: context.run_id,
          reason: inspect(reason)
        )

        error_payload = %{
          type: :failed,
          code: "EGRESS_ERROR",
          message: "egress send failed",
          details: %{reason: inspect(reason)}
        }

        error_payload = ensure_error_egress_result(state, context, error_payload)
        new_state = maybe_mark_processed(state, context, error_payload)
        {{:error, build_error_result(context, error_payload)}, new_state}

      {:error, reason} ->
        Logger.error("dispatch_server.run_dispatch.invalid_event", reason: inspect(reason))

        synthetic_context = fallback_context(inbound_event)

        error_payload = %{
          type: :failed,
          code: "INVALID_EVENT",
          message: "invalid inbound event",
          details: %{reason: inspect(reason)}
        }

        error_payload = ensure_error_egress_result(state, synthetic_context, error_payload)
        {{:error, build_error_result(synthetic_context, error_payload)}, state}
    end
  end

  defp summarize_event(%{} = inbound_event) do
    %{
      request_id: Map.get(inbound_event, :request_id),
      run_id: Map.get(inbound_event, :run_id),
      channel: Map.get(inbound_event, :channel),
      user_id: Map.get(inbound_event, :user_id),
      session_key: Map.get(inbound_event, :session_key)
    }
  end

  defp summarize_event(other), do: %{raw: inspect(other)}

  defp summarize_session_event(event) do
    %{
      type: Map.get(event, :type, Map.get(event, "type")),
      seq: Map.get(event, :seq, Map.get(event, "seq")),
      session_id: Map.get(event, :session_id, Map.get(event, "session_id")),
      turn_id: Map.get(event, :turn_id, Map.get(event, "turn_id")),
      command_id: Map.get(event, :command_id, Map.get(event, "command_id"))
    }
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

  defp ensure_not_duplicate(run_id, state) do
    if MapSet.member?(state.processed_run_ids, run_id), do: {:duplicate, run_id}, else: :ok
  end

  # 将 payload 转为 runtime 可消费的字符串 prompt。
  defp payload_to_prompt(payload) when is_binary(payload), do: {:ok, payload}

  defp payload_to_prompt(payload) do
    case Jason.encode(payload) do
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, {:invalid_payload, reason}}
    end
  end

  defp do_start_turn(state, context) do
    runtime_session_id = resolve_runtime_session_id(state, context.session_key)

    bridge_context =
      %{
        request_id: context.request_id,
        session_key: runtime_session_id,
        external_session_key: context.session_key,
        run_id: context.run_id
      }
      |> maybe_put_event_callback(state, context)

    with {:ok, prompt} <- payload_to_prompt(context.payload) do
      case state.bridge_adapter.start_turn(prompt, bridge_context) do
        {:ok, payload} ->
          {:ok, payload}

        {:error, error_payload} ->
          maybe_invalidate_runtime_session(
            state,
            context.session_key,
            runtime_session_id,
            error_payload
          )

          {:bridge_error, error_payload, context}
      end
    else
      {:error, reason} ->
        {:bridge_error,
         %{
           type: :failed,
           code: "INVALID_PAYLOAD",
           message: "payload encode failed",
           details: %{reason: inspect(reason)}
         }, context}
    end
  end

  defp maybe_put_event_callback(context_map, %{streaming_enabled: true} = state, context) do
    Map.put(context_map, :event_callback, build_event_callback(state, context))
  end

  defp maybe_put_event_callback(context_map, _state, _context), do: context_map

  defp build_event_callback(state, context) do
    fn event ->
      case do_send_event(state, context, event) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("dispatch_server.run_dispatch.event_egress_error",
            request_id: context.request_id,
            run_id: context.run_id,
            reason: inspect(reason)
          )

          :ok
      end
    end
  end

  defp resolve_runtime_session_id(%{session_coordinator_enabled: false}, session_key),
    do: session_key

  defp resolve_runtime_session_id(state, session_key) do
    case safe_get_or_create_runtime_session_id(state.session_coordinator_name, session_key) do
      {:ok, runtime_session_id} ->
        runtime_session_id

      {:error, _reason} ->
        session_key
    end
  end

  # coordinator 可能在调用窗口重启，捕获 exit 以保证 dispatch 可降级。
  defp safe_get_or_create_runtime_session_id(coordinator_name, session_key) do
    try do
      SessionCoordinator.get_or_create(
        coordinator_name,
        session_key,
        &generate_runtime_session_id/0
      )
    catch
      :exit, _reason -> {:error, :session_coordinator_unavailable}
    end
  end

  defp maybe_invalidate_runtime_session(
         %{session_coordinator_enabled: false},
         _session_key,
         _runtime_session_id,
         _error_payload
       ),
       do: :ok

  defp maybe_invalidate_runtime_session(state, session_key, runtime_session_id, error_payload) do
    code =
      error_payload
      |> Map.get(:code)
      |> normalize_error_code()

    if code == "",
      do: :ok,
      else: invalidate_session_mapping(state, session_key, runtime_session_id, code)
  end

  defp invalidate_session_mapping(state, session_key, runtime_session_id, code) do
    _ =
      safe_invalidate_session_mapping(state.session_coordinator_name, %{
        session_key: session_key,
        runtime_session_id: runtime_session_id,
        code: code
      })

    :ok
  end

  # 失效剔除属于尽力而为，coordinator 不可用时不影响主链路返回。
  defp safe_invalidate_session_mapping(coordinator_name, reason) do
    try do
      SessionCoordinator.invalidate_by_session_key(coordinator_name, reason)
    catch
      :exit, _reason -> :ignored
    end
  end

  defp normalize_error_code(code) when is_atom(code),
    do: code |> Atom.to_string() |> String.downcase()

  defp normalize_error_code(code) when is_binary(code),
    do: code |> String.trim() |> String.downcase()

  defp normalize_error_code(_), do: ""

  defp generate_runtime_session_id do
    "runtime-session-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

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

    case state.egress_adapter.send(context.session_key, message) do
      :ok -> :ok
      {:error, reason} -> {:egress_error, reason, context}
    end
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

  defp do_send_event(state, context, %{type: :delta, payload: payload}) do
    stream_payload = normalize_stream_payload(payload)

    message = %EventMessage{
      event_type: :delta,
      payload: stream_payload,
      metadata:
        context.metadata
        |> Map.merge(%{
          request_id: context.request_id,
          run_id: context.run_id,
          session_key: context.session_key,
          seq: System.unique_integer([:positive, :monotonic]),
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        })
        |> Map.merge(stream_metadata(stream_payload))
    }

    state.egress_adapter.send(context.session_key, message)
  end

  defp do_send_event(_state, _context, _event), do: :ok

  defp normalize_stream_payload(payload) when is_map(payload) do
    text =
      case map_value(payload, :text, "") do
        value when is_binary(value) -> value
        _ -> ""
      end

    %{}
    |> Map.put(:text, text)
    |> put_if_binary(:tool_name, map_value(payload, :tool_name, nil))
    |> put_if_binary(:tool_status, map_value(payload, :tool_status, nil))
    |> put_if_binary(:rate_used_pct, map_value(payload, :rate_used_pct, nil))
    |> put_if_binary(:phase, map_value(payload, :phase, nil))
  end

  defp normalize_stream_payload(text) when is_binary(text), do: %{text: text}
  defp normalize_stream_payload(_), do: %{text: ""}

  defp stream_metadata(payload) when is_map(payload) do
    %{}
    |> put_if_binary(:tool_name, Map.get(payload, :tool_name))
    |> put_if_binary(:tool_status, Map.get(payload, :tool_status))
    |> put_if_binary(:rate_used_pct, Map.get(payload, :rate_used_pct))
    |> put_if_binary(:phase, Map.get(payload, :phase))
  end

  defp stream_metadata(_), do: %{}

  defp put_if_binary(map, _key, nil), do: map

  defp put_if_binary(map, key, value) when is_binary(value) do
    Map.put(map, key, value)
  end

  defp put_if_binary(map, _key, _value), do: map

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp mark_processed(state, context) do
    %{
      state
      | processed_run_ids: MapSet.put(state.processed_run_ids, context.run_id),
        session_last_context: Map.put(state.session_last_context, context.session_key, context)
    }
  end

  # egress 失败时不记录已处理，允许同 run_id 做恢复性重试。
  defp maybe_mark_processed(state, _context, %{code: "EGRESS_ERROR"}), do: state
  defp maybe_mark_processed(state, context, _error_payload), do: mark_processed(state, context)

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
