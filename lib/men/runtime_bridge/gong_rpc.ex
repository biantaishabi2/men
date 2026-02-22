defmodule Men.RuntimeBridge.GongRPC do
  @moduledoc """
  基于分布式 Erlang RPC 的 Runtime Bridge 实现。
  """

  @behaviour Men.RuntimeBridge.Bridge

  alias Men.RuntimeBridge.NodeConnector

  @default_rpc_timeout_ms 30_000
  @default_completion_timeout_ms 60_000
  @default_model "deepseek:deepseek-chat"

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
    completion_timeout_ms = timeout_ms(cfg, :completion_timeout_ms, @default_completion_timeout_ms)

    request_id = context_value(context, :request_id, "unknown_request")
    session_key = context_value(context, :session_key, "unknown_session")
    run_id = context_value(context, :run_id, generate_run_id())

    with {:ok, gong_node} <- connector.ensure_connected(cfg, rpc_client),
         {:ok, session_pid, session_id} <-
           create_session(gong_node, rpc_client, cfg, rpc_timeout_ms, request_id, session_key, run_id),
         :ok <- subscribe_session(gong_node, session_pid, rpc_client, rpc_timeout_ms, request_id, session_key, run_id),
         :ok <- prompt_session(gong_node, session_pid, prompt, rpc_client, rpc_timeout_ms, request_id, session_key, run_id),
         {:ok, text} <-
           await_completion(
             gong_node,
             session_pid,
             rpc_client,
             rpc_timeout_ms,
             completion_timeout_ms,
             request_id,
             session_key,
             run_id
           ) do
      safe_close_session(gong_node, session_id, rpc_client, rpc_timeout_ms)

      duration_ms = System.monotonic_time(:millisecond) - started_at

      {:ok,
       %{
         text: text,
         meta: %{
           run_id: run_id,
           request_id: request_id,
           session_key: session_key,
           duration_ms: duration_ms,
           transport: "rpc"
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

  defp create_session(gong_node, rpc_client, cfg, rpc_timeout_ms, request_id, session_key, run_id) do
    model = Keyword.get(cfg, :model, @default_model)
    session_opts = [[model: model]]

    case rpc_client.call(gong_node, Gong.SessionManager, :create_session, session_opts, rpc_timeout_ms) do
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

  defp subscribe_session(gong_node, session_pid, rpc_client, rpc_timeout_ms, request_id, session_key, run_id) do
    case rpc_client.call(gong_node, Gong.Session, :subscribe, [session_pid, self()], rpc_timeout_ms) do
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

  defp prompt_session(gong_node, session_pid, prompt, rpc_client, rpc_timeout_ms, request_id, session_key, run_id) do
    case rpc_client.call(gong_node, Gong.Session, :prompt, [session_pid, prompt, []], rpc_timeout_ms) do
      :ok ->
        :ok

      {:badrpc, reason} ->
        {:error, rpc_error_payload("RPC_PROMPT_FAILED", reason)}

      {:error, reason} ->
        {:error, failed_payload("RPC_PROMPT_FAILED", "session prompt failed", %{reason: inspect(reason)})}

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
         run_id
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
      run_id
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
         run_id
       ) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {:session_event, %{type: "message.delta", payload: payload}} when is_map(payload) ->
        next_delta = delta_text <> to_string(Map.get(payload, :content, Map.get(payload, "content", "")))

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
          run_id
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
          run_id
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
        case rpc_client.call(gong_node, Gong.Session, :get_last_assistant_message, [history], rpc_timeout_ms) do
          text when is_binary(text) and text != "" -> {:ok, text}
          _ -> {:ok, ""}
        end

      {:badrpc, reason} ->
        {:error, rpc_error_payload("RPC_HISTORY_FAILED", reason)}

      other ->
        {:error, failed_payload("RPC_HISTORY_FAILED", "unexpected history result", %{result: inspect(other)})}
    end
  end

  defp safe_close_session(gong_node, session_id, rpc_client, rpc_timeout_ms) do
    _ = rpc_client.call(gong_node, Gong.SessionManager, :close_session, [session_id], rpc_timeout_ms)
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
