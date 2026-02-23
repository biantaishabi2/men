defmodule Men.RuntimeBridge.GongRPC do
  @moduledoc """
  基于分布式 Erlang RPC 的 Runtime Bridge 实现。
  """

  @behaviour Men.RuntimeBridge.Bridge

  require Logger

  alias Men.RuntimeBridge.NodeConnector

  @default_rpc_timeout_ms 30_000
  @default_completion_timeout_ms 60_000
  @default_model "deepseek:deepseek-chat"
  @default_session_idle_ttl_ms 30 * 60 * 1000
  @default_session_cleanup_interval_ms 60 * 1000
  @default_max_session_entries 1_000
  @default_invalidation_codes ["session_not_found", "runtime_session_not_found"]

  @session_table :men_gong_rpc_sessions
  @last_cleanup_key {__MODULE__, :last_cleanup_ms}
  @session_lock_prefix {:men_gong_rpc_lock, :session_key}

  defmodule RPCClient do
    @moduledoc false

    @callback call(node(), module(), atom(), [term()], timeout()) :: term()
    @callback ping(node()) :: :pong | :pang
  end

  defmodule ErlangRPCClient do
    @moduledoc false
    @behaviour RPCClient

    @impl true
    def call(node, module, function, args, timeout) do
      :rpc.call(node, module, function, args, timeout)
    end

    @impl true
    def ping(node), do: Node.ping(node)
  end

  @impl true
  def start_turn(prompt, context) when is_binary(prompt) and is_map(context) do
    started_at = System.monotonic_time(:millisecond)
    cfg = runtime_config()
    rpc_client = Keyword.get(cfg, :rpc_client, ErlangRPCClient)
    connector = Keyword.get(cfg, :node_connector, NodeConnector)
    rpc_timeout_ms = timeout_ms(cfg, :rpc_timeout_ms, @default_rpc_timeout_ms)

    completion_timeout_ms =
      timeout_ms(cfg, :completion_timeout_ms, @default_completion_timeout_ms)

    request_id = context_value(context, :request_id, "unknown_request")
    session_key = context_value(context, :session_key, "unknown_session")
    run_id = context_value(context, :run_id, generate_run_id())
    event_callback = event_callback_from_context(context)

    with {:ok, gong_node} <- connector.ensure_connected(cfg, rpc_client),
         :ok <- maybe_cleanup_sessions(gong_node, rpc_client, cfg, rpc_timeout_ms),
         {:ok, text, _entry, reused?} <-
           run_turn_with_rebuild(
             gong_node,
             rpc_client,
             cfg,
             prompt,
             request_id,
             session_key,
             run_id,
             event_callback,
             rpc_timeout_ms,
             completion_timeout_ms
           ) do
      duration_ms = System.monotonic_time(:millisecond) - started_at

      {:ok,
       %{
         text: text,
         meta: %{
           run_id: run_id,
           request_id: request_id,
           session_key: session_key,
           duration_ms: duration_ms,
           transport: "rpc",
           session_reused: reused?
         }
       }}
    else
      {:error, error_payload} when is_map(error_payload) ->
        {:error, Map.merge(default_context(request_id, session_key, run_id), error_payload)}
    end
  end

  def start_turn(prompt, context) when is_binary(prompt) and is_list(context) do
    start_turn(prompt, Map.new(context))
  end

  def start_turn(_prompt, _context) do
    raise ArgumentError, "start_turn/2 expects prompt binary and context map/keyword"
  end

  @doc false
  def __reset_session_registry_for_test__ do
    if :ets.whereis(@session_table) != :undefined do
      :ets.delete_all_objects(@session_table)
    end

    :persistent_term.erase(@last_cleanup_key)
    :ok
  end

  @doc false
  def __set_session_last_access_for_test__(session_key, last_access_at_ms)
      when is_binary(session_key) and is_integer(last_access_at_ms) do
    ensure_session_table!()
    :ets.update_element(@session_table, session_key, {4, last_access_at_ms})
    :ok
  rescue
    ArgumentError ->
      :ok
  end

  @doc false
  def __force_cleanup_next_turn_for_test__ do
    :persistent_term.erase(@last_cleanup_key)
    :ok
  end

  defp run_turn_with_rebuild(
         gong_node,
         rpc_client,
         cfg,
         prompt,
         request_id,
         session_key,
         run_id,
         event_callback,
         rpc_timeout_ms,
         completion_timeout_ms
       ) do
    with {:ok, entry, reused?} <-
           get_or_create_session_entry(
             gong_node,
             rpc_client,
             cfg,
             rpc_timeout_ms,
             request_id,
             session_key,
             run_id
           ) do
      case run_turn(
             gong_node,
             entry.session_pid,
             rpc_client,
             cfg,
             prompt,
             rpc_timeout_ms,
             completion_timeout_ms,
             request_id,
             session_key,
             run_id,
             event_callback
           ) do
        {:ok, text} ->
          touch_session_entry(session_key)
          {:ok, text, entry, reused?}

        {:error, error_payload} ->
          if should_rebuild_session?(cfg, error_payload) do
            Logger.warning("gong_rpc.session.rebuild",
              session_key: session_key,
              run_id: run_id,
              reason: Map.get(error_payload, :code, "unknown")
            )

            invalidate_session_entry(gong_node, rpc_client, rpc_timeout_ms, session_key, :error)

            with {:ok, rebuilt_entry, _reused?} <-
                   get_or_create_session_entry(
                     gong_node,
                     rpc_client,
                     cfg,
                     rpc_timeout_ms,
                     request_id,
                     session_key,
                     run_id
                   ),
                 {:ok, rebuilt_text} <-
                   run_turn(
                     gong_node,
                     rebuilt_entry.session_pid,
                     rpc_client,
                     cfg,
                     prompt,
                     rpc_timeout_ms,
                     completion_timeout_ms,
                     request_id,
                     session_key,
                     run_id,
                     event_callback
                   ) do
              touch_session_entry(session_key)
              {:ok, rebuilt_text, rebuilt_entry, false}
            end
          else
            {:error, error_payload}
          end
      end
    end
  end

  defp run_turn(
         gong_node,
         session_pid,
         rpc_client,
         _cfg,
         prompt,
         rpc_timeout_ms,
         completion_timeout_ms,
         request_id,
         session_key,
         run_id,
         event_callback
       ) do
    with :ok <-
           subscribe_session(
             gong_node,
             session_pid,
             rpc_client,
             rpc_timeout_ms,
             request_id,
             session_key,
             run_id
           ),
         :ok <-
           prompt_session(
             gong_node,
             session_pid,
             prompt,
             rpc_client,
             rpc_timeout_ms,
             request_id,
             session_key,
             run_id
           ),
         {:ok, text} <-
           await_completion(
             gong_node,
             session_pid,
             rpc_client,
             rpc_timeout_ms,
             completion_timeout_ms,
             request_id,
             session_key,
             run_id,
             event_callback
           ) do
      {:ok, text}
    end
  end

  defp get_or_create_session_entry(
         gong_node,
         rpc_client,
         cfg,
         rpc_timeout_ms,
         request_id,
         session_key,
         run_id
       ) do
    lock_session_key(session_key, fn ->
      case lookup_session_entry(session_key) do
        {:ok, entry} ->
          touch_session_entry(session_key)
          Logger.debug("gong_rpc.session.hit", session_key: session_key, run_id: run_id)
          {:ok, entry, true}

        :error ->
          with {:ok, session_pid, session_id} <-
                 create_session(
                   gong_node,
                   rpc_client,
                   cfg,
                   rpc_timeout_ms,
                   request_id,
                   session_key,
                   run_id
                 ),
               :ok <-
                 subscribe_session(
                   gong_node,
                   session_pid,
                   rpc_client,
                   rpc_timeout_ms,
                   request_id,
                   session_key,
                   run_id
                 ) do
            entry = %{
              session_key: session_key,
              session_id: session_id,
              session_pid: session_pid,
              last_access_at_ms: now_ms()
            }

            put_session_entry(entry)

            Logger.info("gong_rpc.session.created",
              session_key: session_key,
              session_id: session_id,
              run_id: run_id
            )

            {:ok, entry, false}
          end
      end
    end)
  end

  defp maybe_cleanup_sessions(gong_node, rpc_client, cfg, rpc_timeout_ms) do
    interval_ms =
      timeout_ms(cfg, :session_cleanup_interval_ms, @default_session_cleanup_interval_ms)

    current = now_ms()
    last = :persistent_term.get(@last_cleanup_key, 0)

    if current - last >= interval_ms do
      :persistent_term.put(@last_cleanup_key, current)

      cleanup_expired_sessions(gong_node, rpc_client, cfg, rpc_timeout_ms, current)
      cleanup_lru_sessions(gong_node, rpc_client, cfg, rpc_timeout_ms)
    end

    :ok
  end

  defp cleanup_expired_sessions(gong_node, rpc_client, cfg, rpc_timeout_ms, current_ms) do
    ttl_ms = timeout_ms(cfg, :session_idle_ttl_ms, @default_session_idle_ttl_ms)

    list_session_entries()
    |> Enum.filter(fn entry -> current_ms - entry.last_access_at_ms >= ttl_ms end)
    |> Enum.each(fn entry ->
      close_and_remove_session(gong_node, rpc_client, rpc_timeout_ms, entry, :ttl)
    end)
  end

  defp cleanup_lru_sessions(gong_node, rpc_client, cfg, rpc_timeout_ms) do
    max_entries = timeout_ms(cfg, :max_session_entries, @default_max_session_entries)
    entries = list_session_entries()
    overflow = max(length(entries) - max_entries, 0)

    if overflow > 0 do
      entries
      |> Enum.sort_by(& &1.last_access_at_ms, :asc)
      |> Enum.take(overflow)
      |> Enum.each(fn entry ->
        close_and_remove_session(gong_node, rpc_client, rpc_timeout_ms, entry, :lru)
      end)
    end
  end

  defp invalidate_session_entry(gong_node, rpc_client, rpc_timeout_ms, session_key, reason) do
    lock_session_key(session_key, fn ->
      case lookup_session_entry(session_key) do
        {:ok, entry} ->
          close_and_remove_session(gong_node, rpc_client, rpc_timeout_ms, entry, reason)
          :ok

        :error ->
          :ok
      end
    end)
  end

  defp close_and_remove_session(gong_node, rpc_client, rpc_timeout_ms, entry, reason) do
    safe_close_session(gong_node, entry.session_id, rpc_client, rpc_timeout_ms)
    delete_session_entry(entry.session_key)

    Logger.info("gong_rpc.session.closed",
      session_key: entry.session_key,
      session_id: entry.session_id,
      reason: reason
    )
  end

  defp lock_session_key(session_key, fun) when is_function(fun, 0) do
    :global.trans({@session_lock_prefix, session_key}, fun)
  end

  defp ensure_session_table! do
    case :ets.whereis(@session_table) do
      :undefined ->
        heir_pid = Process.whereis(:init)

        table_opts = [
          :named_table,
          :set,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ]

        table_opts =
          if is_pid(heir_pid) do
            table_opts ++ [{:heir, heir_pid, :transfer}]
          else
            table_opts
          end

        :ets.new(@session_table, table_opts)
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end

  defp lookup_session_entry(session_key) do
    ensure_session_table!()

    case :ets.lookup(@session_table, session_key) do
      [{^session_key, session_id, session_pid, last_access_at_ms}] ->
        {:ok,
         %{
           session_key: session_key,
           session_id: session_id,
           session_pid: session_pid,
           last_access_at_ms: last_access_at_ms
         }}

      _ ->
        :error
    end
  end

  defp put_session_entry(entry) do
    ensure_session_table!()

    :ets.insert(
      @session_table,
      {entry.session_key, entry.session_id, entry.session_pid, entry.last_access_at_ms}
    )

    :ok
  end

  defp touch_session_entry(session_key) do
    ensure_session_table!()
    :ets.update_element(@session_table, session_key, {4, now_ms()})
    :ok
  rescue
    ArgumentError ->
      :ok
  end

  defp delete_session_entry(session_key) do
    ensure_session_table!()
    :ets.delete(@session_table, session_key)
    :ok
  end

  defp list_session_entries do
    ensure_session_table!()

    :ets.tab2list(@session_table)
    |> Enum.map(fn {session_key, session_id, session_pid, last_access_at_ms} ->
      %{
        session_key: session_key,
        session_id: session_id,
        session_pid: session_pid,
        last_access_at_ms: last_access_at_ms
      }
    end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp should_rebuild_session?(cfg, error_payload) when is_map(error_payload) do
    invalidation_codes = invalidation_codes(cfg)
    code = normalize_code(Map.get(error_payload, :code))
    message = normalize_text(Map.get(error_payload, :message))
    reason = error_payload |> Map.get(:details, %{}) |> Map.get(:reason) |> normalize_text()

    code in invalidation_codes or
      String.contains?(message, "session_not_found") or
      String.contains?(message, "runtime session missing") or
      String.contains?(reason, "session_not_found") or
      String.contains?(reason, "noproc") or
      String.contains?(reason, "not_found")
  end

  defp should_rebuild_session?(_cfg, _error_payload), do: false

  defp invalidation_codes(cfg) do
    cfg
    |> Keyword.get(:session_invalidation_codes, @default_invalidation_codes)
    |> Enum.map(&normalize_code/1)
  end

  defp normalize_code(nil), do: ""
  defp normalize_code(code) when is_atom(code), do: code |> Atom.to_string() |> String.downcase()
  defp normalize_code(code) when is_binary(code), do: String.downcase(code)
  defp normalize_code(code), do: code |> to_string() |> String.downcase()

  defp normalize_text(nil), do: ""
  defp normalize_text(value) when is_binary(value), do: String.downcase(value)
  defp normalize_text(value), do: value |> to_string() |> String.downcase()

  defp create_session(gong_node, rpc_client, cfg, rpc_timeout_ms, request_id, session_key, run_id) do
    model = Keyword.get(cfg, :model, @default_model)
    session_opts = [[model: model]]

    case rpc_client.call(
           gong_node,
           Gong.SessionManager,
           :create_session,
           session_opts,
           rpc_timeout_ms
         ) do
      {:ok, pid, session_id} when is_pid(pid) and is_binary(session_id) ->
        {:ok, pid, session_id}

      {:badrpc, reason} ->
        {:error, rpc_error_payload("RPC_CREATE_SESSION_FAILED", reason)}

      other ->
        {:error,
         failed_payload("RPC_CREATE_SESSION_FAILED", "unexpected create_session result", %{
           result: inspect(other),
           request_id: request_id,
           session_key: session_key,
           run_id: run_id
         })}
    end
  end

  defp subscribe_session(
         gong_node,
         session_pid,
         rpc_client,
         rpc_timeout_ms,
         request_id,
         session_key,
         run_id
       ) do
    case rpc_client.call(
           gong_node,
           Gong.Session,
           :subscribe,
           [session_pid, self()],
           rpc_timeout_ms
         ) do
      :ok ->
        :ok

      {:badrpc, reason} ->
        {:error, rpc_error_payload("RPC_SUBSCRIBE_FAILED", reason)}

      other ->
        {:error,
         failed_payload("RPC_SUBSCRIBE_FAILED", "unexpected subscribe result", %{
           result: inspect(other),
           request_id: request_id,
           session_key: session_key,
           run_id: run_id
         })}
    end
  end

  defp prompt_session(
         gong_node,
         session_pid,
         prompt,
         rpc_client,
         rpc_timeout_ms,
         request_id,
         session_key,
         run_id
       ) do
    case rpc_client.call(
           gong_node,
           Gong.Session,
           :prompt,
           [session_pid, prompt, []],
           rpc_timeout_ms
         ) do
      :ok ->
        :ok

      {:badrpc, reason} ->
        {:error, rpc_error_payload("RPC_PROMPT_FAILED", reason)}

      {:error, reason} ->
        {:error,
         failed_payload("RPC_PROMPT_FAILED", "session prompt failed", %{reason: inspect(reason)})}

      other ->
        {:error,
         failed_payload("RPC_PROMPT_FAILED", "unexpected prompt result", %{
           result: inspect(other),
           request_id: request_id,
           session_key: session_key,
           run_id: run_id
         })}
    end
  end

  defp await_completion(
         gong_node,
         session_pid,
         rpc_client,
         rpc_timeout_ms,
         completion_timeout_ms,
         request_id,
         session_key,
         run_id,
         event_callback
       ) do
    deadline_ms = System.monotonic_time(:millisecond) + completion_timeout_ms

    do_await_completion(
      deadline_ms,
      completion_timeout_ms,
      nil,
      "",
      gong_node,
      session_pid,
      rpc_client,
      rpc_timeout_ms,
      request_id,
      session_key,
      run_id,
      event_callback
    )
  end

  defp do_await_completion(
         deadline_ms,
         completion_timeout_ms,
         result_text,
         delta_text,
         gong_node,
         session_pid,
         rpc_client,
         rpc_timeout_ms,
         request_id,
         session_key,
         run_id,
         event_callback
       ) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {:session_event, %{type: "message.delta", payload: payload}} when is_map(payload) ->
        delta_chunk = to_string(Map.get(payload, :content, Map.get(payload, "content", "")))
        next_delta = delta_text <> delta_chunk
        emit_event(event_callback, %{type: :delta, payload: %{text: delta_chunk}})

        do_await_completion(
          deadline_ms,
          completion_timeout_ms,
          result_text,
          next_delta,
          gong_node,
          session_pid,
          rpc_client,
          rpc_timeout_ms,
          request_id,
          session_key,
          run_id,
          event_callback
        )

      {:session_event, %{type: "tool.start", payload: payload}} when is_map(payload) ->
        tool_name = Map.get(payload, :tool_name, Map.get(payload, "tool_name", "unknown_tool"))

        emit_event(event_callback, %{
          type: :delta,
          payload: %{text: "", tool_name: tool_name, tool_status: "start"}
        })

        do_await_completion(
          deadline_ms,
          completion_timeout_ms,
          result_text,
          delta_text,
          gong_node,
          session_pid,
          rpc_client,
          rpc_timeout_ms,
          request_id,
          session_key,
          run_id,
          event_callback
        )

      {:session_event, %{type: "tool.end", payload: payload}} when is_map(payload) ->
        tool_name = Map.get(payload, :tool_name, Map.get(payload, "tool_name", "unknown_tool"))

        emit_event(event_callback, %{
          type: :delta,
          payload: %{text: "", tool_name: tool_name, tool_status: "end"}
        })

        do_await_completion(
          deadline_ms,
          completion_timeout_ms,
          result_text,
          delta_text,
          gong_node,
          session_pid,
          rpc_client,
          rpc_timeout_ms,
          request_id,
          session_key,
          run_id,
          event_callback
        )

      {:session_event, %{type: "lifecycle.result", payload: payload}} when is_map(payload) ->
        assistant_text = Map.get(payload, :assistant_text, Map.get(payload, "assistant_text"))

        next_result =
          case assistant_text do
            text when is_binary(text) and text != "" -> text
            _ -> result_text
          end

        do_await_completion(
          deadline_ms,
          completion_timeout_ms,
          next_result,
          delta_text,
          gong_node,
          session_pid,
          rpc_client,
          rpc_timeout_ms,
          request_id,
          session_key,
          run_id,
          event_callback
        )

      {:session_event, %{type: "lifecycle.error", error: error}} ->
        {:error,
         failed_payload("RPC_LIFECYCLE_ERROR", "gong session lifecycle.error", %{
           error: inspect(error),
           request_id: request_id,
           session_key: session_key,
           run_id: run_id
         })}

      {:session_event, %{type: "lifecycle.completed"}} ->
        text = finalize_text(result_text, delta_text)

        if text == "" do
          fetch_history_text(gong_node, session_pid, rpc_client, rpc_timeout_ms)
        else
          {:ok, text}
        end

      {:session_event, _other_event} ->
        # 会话事件流中包含大量生命周期/工具事件，这些不是 completion 判定条件。
        # 显式消费后继续等待，避免残留到上层 GenServer mailbox。
        do_await_completion(
          deadline_ms,
          completion_timeout_ms,
          result_text,
          delta_text,
          gong_node,
          session_pid,
          rpc_client,
          rpc_timeout_ms,
          request_id,
          session_key,
          run_id,
          event_callback
        )
    after
      remaining_ms ->
        {:error,
         %{
           type: :timeout,
           code: "RPC_TIMEOUT",
           message: "gong rpc completion timed out after #{completion_timeout_ms}ms",
           details: %{
             waited_ms: completion_timeout_ms - max(remaining_ms, 0),
             request_id: request_id,
             session_key: session_key,
             run_id: run_id
           }
         }}
    end
  end

  defp fetch_history_text(gong_node, session_pid, rpc_client, rpc_timeout_ms) do
    case rpc_client.call(gong_node, Gong.Session, :history, [session_pid], rpc_timeout_ms) do
      {:ok, history} when is_list(history) ->
        case rpc_client.call(
               gong_node,
               Gong.Session,
               :get_last_assistant_message,
               [history],
               rpc_timeout_ms
             ) do
          text when is_binary(text) and text != "" -> {:ok, text}
          _ -> {:ok, ""}
        end

      {:badrpc, reason} ->
        {:error, rpc_error_payload("RPC_HISTORY_FAILED", reason)}

      other ->
        {:error,
         failed_payload("RPC_HISTORY_FAILED", "unexpected history result", %{
           result: inspect(other)
         })}
    end
  end

  defp safe_close_session(gong_node, session_id, rpc_client, rpc_timeout_ms) do
    _ =
      rpc_client.call(
        gong_node,
        Gong.SessionManager,
        :close_session,
        [session_id],
        rpc_timeout_ms
      )

    :ok
  end

  defp finalize_text(result_text, delta_text) do
    cond do
      is_binary(result_text) and result_text != "" -> result_text
      is_binary(delta_text) and delta_text != "" -> delta_text
      true -> ""
    end
  end

  defp runtime_config do
    Application.get_env(:men, __MODULE__, [])
  end

  defp timeout_ms(cfg, key, default) do
    case Keyword.get(cfg, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp context_value(context, key, default) do
    context
    |> Map.get(key, Map.get(context, Atom.to_string(key), default))
    |> normalize_context_value(default)
  end

  defp event_callback_from_context(context) when is_map(context) do
    callback = Map.get(context, :event_callback, Map.get(context, "event_callback"))
    if is_function(callback, 1), do: callback, else: nil
  end

  defp event_callback_from_context(_), do: nil

  defp emit_event(nil, _event), do: :ok

  defp emit_event(callback, event) when is_function(callback, 1) do
    try do
      callback.(event)
    rescue
      _ -> :ok
    end
  end

  defp normalize_context_value(nil, default), do: default
  defp normalize_context_value("", default), do: default
  defp normalize_context_value(value, _default) when is_binary(value), do: value
  defp normalize_context_value(value, _default), do: to_string(value)

  defp generate_run_id do
    "run_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 16)
  end

  defp default_context(request_id, session_key, run_id) do
    %{
      request_id: request_id,
      session_key: session_key,
      run_id: run_id
    }
  end

  defp rpc_error_payload(code, reason) do
    failed_payload(code, "rpc call failed", %{reason: inspect(reason)})
  end

  defp failed_payload(code, message, details) do
    %{
      type: :failed,
      code: code,
      message: message,
      details: details
    }
  end
end
