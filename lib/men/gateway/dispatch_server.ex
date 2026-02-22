defmodule Men.Gateway.DispatchServer do
  @moduledoc """
  L1 主状态机：串联 inbound -> runtime bridge -> egress。
  """

  use GenServer

  alias Men.Channels.Egress.Messages
  alias Men.Channels.Egress.Messages.EventMessage
  alias Men.Gateway.SessionCoordinator
  alias Men.Gateway.Types
  alias Men.Routing.SessionKey

  @type run_state :: %{
          seq: non_neg_integer(),
          terminal?: boolean()
        }

  @type state :: %{
          bridge_adapter: module(),
          egress_adapter: module(),
          storage_adapter: term(),
          chat_streaming_enabled: boolean(),
          session_coordinator_enabled: boolean(),
          session_coordinator_name: GenServer.server(),
          processed_run_ids: MapSet.t(binary()),
          run_states: %{optional(binary()) => run_state()},
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
      chat_streaming_enabled:
        Keyword.get(opts, :chat_streaming_enabled, Keyword.get(config, :chat_streaming_enabled, true)),
      session_coordinator_enabled:
        Keyword.get(opts, :session_coordinator_enabled, Keyword.get(coordinator_config, :enabled, true)),
      session_coordinator_name:
        Keyword.get(opts, :session_coordinator_name, SessionCoordinator),
      processed_run_ids: MapSet.new(),
      run_states: %{},
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

  defp run_dispatch(state, inbound_event) do
    with {:ok, context} <- normalize_event(inbound_event),
         :ok <- ensure_not_duplicate(context.run_id, state),
         {:ok, bridge_payload, state_after_stream} <- do_start_turn(state, context) do
      new_state = mark_processed(state_after_stream, context)
      {{:ok, build_dispatch_result(context, bridge_payload)}, new_state}
    else
      {:duplicate, run_id} ->
        _ = run_id
        {{:ok, :duplicate}, state}

      {:bridge_error, error_payload, context, state_after_stream} ->
        new_state = maybe_mark_processed(state_after_stream, context, error_payload)
        {{:error, build_error_result(context, error_payload)}, new_state}

      {:egress_error, reason, context, state_after_stream} ->
        error_payload = %{
          type: :failed,
          code: "EGRESS_ERROR",
          message: "egress send failed",
          details: %{reason: inspect(reason)}
        }

        {error_payload, state_after_error} =
          ensure_error_egress_result(state_after_stream, context, error_payload)

        new_state = maybe_mark_processed(state_after_error, context, error_payload)
        {{:error, build_error_result(context, error_payload)}, new_state}

      {:error, reason} ->
        synthetic_context = fallback_context(inbound_event)

        error_payload = %{
          type: :failed,
          code: "INVALID_EVENT",
          message: "invalid inbound event",
          details: %{reason: inspect(reason)}
        }

        {error_payload, _state_after_error} =
          ensure_error_egress_result(state, synthetic_context, error_payload)

        {{:error, build_error_result(synthetic_context, error_payload)}, state}
    end
  end

  # 错误回写失败时统一抬升为 egress 失败，避免调用方误判。
  defp ensure_error_egress_result(state, context, error_payload) do
    case dispatch_error_event(state, context, error_payload) do
      {:ok, _standard_error_payload, new_state} ->
        {error_payload, new_state}

      {:egress_error, reason, new_state} ->
        {Map.merge(error_payload, %{code: "EGRESS_ERROR", message: "egress send failed", details: %{reason: inspect(reason)}}), new_state}
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

    bridge_context = %{
      request_id: context.request_id,
      session_key: runtime_session_id,
      external_session_key: context.session_key,
      run_id: context.run_id
    }

    with {:ok, prompt} <- payload_to_prompt(context.payload) do
      case state.bridge_adapter.start_turn(prompt, bridge_context) do
        {:ok, bridge_payload} ->
          with {:ok, events} <- normalize_bridge_events(bridge_payload),
               {:ok, delivered_events, state_after_stream} <- dispatch_events(state, context, events) do
            {:ok, %{bridge_payload: bridge_payload, events: delivered_events}, state_after_stream}
          else
            {:egress_error, reason, state_after_stream} ->
              {:egress_error, reason, context, state_after_stream}

            {:error, reason} ->
              error_payload = %{
                type: :failed,
                code: "INVALID_BRIDGE_PAYLOAD",
                message: "bridge returned invalid payload",
                details: %{reason: inspect(reason)}
              }

              case dispatch_error_event(state, context, error_payload) do
                {:ok, standard_error_payload, state_after_error} ->
                  {:bridge_error, standard_error_payload, context, state_after_error}

                {:egress_error, reason, state_after_error} ->
                  {:egress_error, reason, context, state_after_error}
              end
          end

        {:error, error_payload} ->
          maybe_invalidate_runtime_session(state, context.session_key, runtime_session_id, error_payload)

          case dispatch_error_event(state, context, error_payload) do
            {:ok, standard_error_payload, state_after_error} ->
              {:bridge_error, standard_error_payload, context, state_after_error}

            {:egress_error, reason, state_after_error} ->
              {:egress_error, reason, context, state_after_error}
          end
      end
    else
      {:error, reason} ->
        error_payload = %{
          type: :failed,
          code: "INVALID_PAYLOAD",
          message: "payload encode failed",
          details: %{reason: inspect(reason)}
        }

        case dispatch_error_event(state, context, error_payload) do
          {:ok, standard_error_payload, state_after_error} ->
            {:bridge_error, standard_error_payload, context, state_after_error}

          {:egress_error, reason, state_after_error} ->
            {:egress_error, reason, context, state_after_error}
        end
    end
  end

  defp dispatch_events(state, context, events) do
    events
    |> maybe_filter_delta(state.chat_streaming_enabled)
    |> Enum.reduce_while({:ok, [], state}, fn event, {:ok, delivered, acc_state} ->
      case dispatch_single_event(acc_state, context, event) do
        {:ok, nil, next_state} -> {:cont, {:ok, delivered, next_state}}
        {:ok, %EventMessage{} = message, next_state} -> {:cont, {:ok, [message | delivered], next_state}}
        {:egress_error, reason, next_state} -> {:halt, {:egress_error, reason, next_state}}
      end
    end)
    |> case do
      {:ok, delivered, next_state} -> {:ok, Enum.reverse(delivered), next_state}
      other -> other
    end
  end

  defp maybe_filter_delta(events, true), do: events

  defp maybe_filter_delta(events, false) do
    Enum.reject(events, fn event -> event.event_type == :delta end)
  end

  # final 终态后拒收后续 delta，避免迟到片段污染。
  defp dispatch_single_event(state, context, %{event_type: :delta} = event) do
    if run_terminal?(state, context.run_id), do: {:ok, nil, state}, else: send_event(state, context, event)
  end

  defp dispatch_single_event(state, context, event), do: send_event(state, context, event)

  defp send_event(state, context, event) do
    seq = next_seq_for_run(state, context.run_id)

    required_metadata = %{
      request_id: context.request_id,
      run_id: context.run_id,
      session_key: context.session_key,
      seq: seq,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    merged_metadata =
      context.metadata
      |> Map.merge(Map.get(event, :metadata, %{}))

    with {:ok, message} <-
           Messages.event_message(event.event_type, event.payload, merged_metadata, required_metadata),
         :ok <- state.egress_adapter.send(context.session_key, message) do
      {:ok, message, advance_run_state(state, context.run_id, event.event_type, seq)}
    else
      {:error, reason} -> {:egress_error, reason, state}
    end
  end

  defp dispatch_error_event(state, context, error_payload) do
    standard_error_payload = standardize_error_payload(error_payload)

    error_event = %{
      event_type: :error,
      payload: %{
        reason: standard_error_payload.message,
        code: standard_error_payload.code,
        type: standard_error_payload.type,
        details: standard_error_payload.details
      },
      metadata: %{
        type: standard_error_payload.type,
        details: standard_error_payload.details
      }
    }

    case dispatch_events(state, context, [error_event]) do
      {:ok, _messages, new_state} -> {:ok, standard_error_payload, new_state}
      {:egress_error, reason, new_state} -> {:egress_error, reason, new_state}
    end
  end

  defp normalize_bridge_events(%{events: events}) when is_list(events), do: normalize_event_list(events)
  defp normalize_bridge_events(%{"events" => events}) when is_list(events), do: normalize_event_list(events)
  defp normalize_bridge_events(events) when is_list(events), do: normalize_event_list(events)

  defp normalize_bridge_events(%{} = payload) do
    if Map.has_key?(payload, :event_type) or Map.has_key?(payload, "event_type") do
      normalize_event_list([payload])
    else
      {:ok,
       [
         %{
           event_type: :final,
           payload: %{text: Map.get(payload, :text, Map.get(payload, "text", ""))},
           metadata: Map.get(payload, :meta, Map.get(payload, :metadata, %{}))
         }
       ]}
    end
  end

  defp normalize_bridge_events(payload) when is_binary(payload) do
    {:ok, [%{event_type: :final, payload: %{text: payload}, metadata: %{}}]}
  end

  defp normalize_bridge_events(other), do: {:error, {:invalid_bridge_payload, other}}

  defp normalize_event_list(events) do
    Enum.reduce_while(events, {:ok, []}, fn raw_event, {:ok, acc} ->
      case normalize_bridge_event(raw_event) do
        {:ok, normalized_event} -> {:cont, {:ok, [normalized_event | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  defp normalize_bridge_event(%{} = event) do
    event_type =
      Map.get(event, :event_type) ||
        Map.get(event, "event_type") ||
        Map.get(event, :type) ||
        Map.get(event, "type")

    with {:ok, normalized_event_type} <- normalize_event_type(event_type),
         {:ok, payload} <- normalize_event_payload(normalized_event_type, event),
         {:ok, metadata} <- normalize_event_metadata(event) do
      {:ok, %{event_type: normalized_event_type, payload: payload, metadata: metadata}}
    end
  end

  defp normalize_bridge_event(other), do: {:error, {:invalid_bridge_event, other}}

  defp normalize_event_type(type) when is_atom(type) do
    if type in [:delta, :final, :error], do: {:ok, type}, else: {:error, {:invalid_event_type, type}}
  end

  defp normalize_event_type(type) when is_binary(type) do
    case String.downcase(String.trim(type)) do
      "delta" -> {:ok, :delta}
      "final" -> {:ok, :final}
      "error" -> {:ok, :error}
      other -> {:error, {:invalid_event_type, other}}
    end
  end

  defp normalize_event_type(_), do: {:ok, :final}

  defp normalize_event_payload(:delta, event) do
    text = event_text(event)
    {:ok, %{text: text}}
  end

  defp normalize_event_payload(:final, event) do
    payload = Map.get(event, :payload, Map.get(event, "payload"))

    cond do
      is_map(payload) -> {:ok, payload}
      is_binary(payload) -> {:ok, %{text: payload}}
      true -> {:ok, %{text: event_text(event)}}
    end
  end

  defp normalize_event_payload(:error, event) do
    payload = Map.get(event, :payload, Map.get(event, "payload"))

    cond do
      is_map(payload) ->
        reason =
          Map.get(payload, :reason) ||
            Map.get(payload, "reason") ||
            Map.get(payload, :message) ||
            Map.get(payload, "message") ||
            "dispatch failed"

        {:ok,
         %{
           reason: reason,
           code: Map.get(payload, :code, Map.get(payload, "code")),
           type: Map.get(payload, :type, Map.get(payload, "type", :failed)),
           details: Map.get(payload, :details, Map.get(payload, "details"))
         }}

      true ->
        {:ok,
         %{
           reason: event_text(event),
           code: Map.get(event, :code, Map.get(event, "code")),
           type: Map.get(event, :type, Map.get(event, "type", :failed)),
           details: Map.get(event, :details, Map.get(event, "details"))
         }}
    end
  end

  defp normalize_event_metadata(event) do
    metadata =
      Map.get(event, :metadata) ||
        Map.get(event, "metadata") ||
        Map.get(event, :meta) ||
        Map.get(event, "meta") ||
        %{}

    if is_map(metadata), do: {:ok, metadata}, else: {:ok, %{}}
  end

  defp event_text(event) do
    Map.get(event, :text) ||
      Map.get(event, "text") ||
      Map.get(event, :content) ||
      Map.get(event, "content") ||
      ""
  end

  defp standardize_error_payload(error_payload) do
    payload = if is_map(error_payload), do: error_payload, else: %{}

    %{
      type: Map.get(payload, :type, :failed),
      code: stringify_error_field(Map.get(payload, :code), "DISPATCH_ERROR"),
      message: stringify_error_field(Map.get(payload, :message), "dispatch failed"),
      details: Map.get(payload, :details)
    }
  end

  # 错误字段允许结构化输入，统一降级为可读字符串，避免 String.Chars 崩溃。
  defp stringify_error_field(nil, default), do: default
  defp stringify_error_field(value, _default) when is_binary(value), do: value
  defp stringify_error_field(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp stringify_error_field(value, _default) when is_integer(value), do: Integer.to_string(value)
  defp stringify_error_field(value, _default) when is_float(value), do: :erlang.float_to_binary(value, [:compact])
  defp stringify_error_field(value, _default), do: inspect(value)

  defp run_terminal?(state, run_id) do
    state
    |> Map.get(:run_states, %{})
    |> Map.get(run_id, %{terminal?: false})
    |> Map.get(:terminal?, false)
  end

  defp next_seq_for_run(state, run_id) do
    state
    |> Map.get(:run_states, %{})
    |> Map.get(run_id, %{seq: 0})
    |> Map.get(:seq, 0)
    |> Kernel.+(1)
  end

  defp advance_run_state(state, run_id, event_type, seq) do
    terminal? = event_type in [:final, :error]

    run_state = %{
      seq: seq,
      terminal?: terminal?
    }

    %{state | run_states: Map.put(state.run_states, run_id, run_state)}
  end

  defp resolve_runtime_session_id(%{session_coordinator_enabled: false}, session_key), do: session_key

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
      SessionCoordinator.get_or_create(coordinator_name, session_key, &generate_runtime_session_id/0)
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

    if code == "", do: :ok, else: invalidate_session_mapping(state, session_key, runtime_session_id, code)
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

  defp normalize_error_code(code) when is_atom(code), do: code |> Atom.to_string() |> String.downcase()
  defp normalize_error_code(code) when is_binary(code), do: code |> String.trim() |> String.downcase()
  defp normalize_error_code(_), do: ""

  defp generate_runtime_session_id do
    "runtime-session-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp mark_processed(state, context) do
    %{
      state
      | processed_run_ids: MapSet.put(state.processed_run_ids, context.run_id),
        run_states: Map.delete(state.run_states, context.run_id),
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
