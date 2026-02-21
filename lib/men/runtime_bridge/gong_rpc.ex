defmodule Men.RuntimeBridge.GongRPC do
  @moduledoc """
  基于 Erlang RPC 的 RuntimeBridge 实现。

  该模块保持无状态：不在进程内缓存任何会话或复用信息，
  仅负责 RPC 调用、超时控制与错误映射。
  """

  @behaviour Men.RuntimeBridge.Bridge

  alias Men.RuntimeBridge.{Error, Request, Response}

  @default_runtime_id "gong"
  @default_timeout_ms 30_000

  @impl true
  def open(%Request{} = request, opts \\ []) do
    invoke(:open, request, opts)
  end

  @impl true
  def get(%Request{} = request, opts \\ []) do
    invoke(:get, request, opts)
  end

  @impl true
  def prompt(%Request{} = request, opts \\ []) do
    invoke(:prompt, request, opts)
  end

  @impl true
  def close(%Request{} = request, opts \\ []) do
    case invoke(:close, request, opts) do
      {:error, %Error{code: :session_not_found}} ->
        {:ok,
         %Response{
           runtime_id: normalize_runtime_id(request.runtime_id),
           session_id: request.session_id,
           payload: :closed,
           metadata: %{idempotent: true, reason: :session_not_found}
         }}

      other ->
        other
    end
  end

  @impl true
  def start_turn(prompt_text, context) when is_binary(prompt_text) and is_map(context) do
    request =
      %Request{
        runtime_id: normalize_runtime_id(Map.get(context, :runtime_id) || Map.get(context, "runtime_id")),
        session_id:
          Map.get(context, :session_id) || Map.get(context, "session_id") ||
            Map.get(context, :session_key) || Map.get(context, "session_key"),
        payload: prompt_text,
        opts: Map.drop(context, [:runtime_id, :session_id, :session_key]),
        timeout_ms: nil
      }

    case prompt(request, []) do
      {:ok, %Response{} = response} ->
        metadata = normalize_metadata(response.metadata)

        {:ok,
         %{
           text: normalize_payload_text(response.payload),
           meta: Map.merge(metadata, %{runtime_id: response.runtime_id, session_key: response.session_id})
         }}

      {:error, %Error{} = error} ->
        {:error,
         %{
           type: :failed,
           code: Atom.to_string(error.code),
           message: error.message,
           run_id: Map.get(context, :run_id),
           request_id: Map.get(context, :request_id),
           session_key: Map.get(context, :session_key),
           details: error.context
         }}
    end
  end

  def start_turn(prompt_text, context) when is_binary(prompt_text) and is_list(context) do
    start_turn(prompt_text, Map.new(context))
  end

  def start_turn(_prompt_text, _context) do
    raise ArgumentError, "start_turn/2 expects prompt binary and context map/keyword"
  end

  defp invoke(action, %Request{} = request, opts) do
    config = runtime_config()
    timeout_ms = resolve_timeout(request.timeout_ms, opts, config)
    node_name = Keyword.get(opts, :gong_node, Keyword.get(config, :gong_node, node()))
    rpc_module = Keyword.get(opts, :rpc_module, Keyword.get(config, :rpc_module, :rpc))

    {remote_module, remote_function} = resolve_remote_target(action, opts, config)

    rpc_payload = %{
      runtime_id: normalize_runtime_id(request.runtime_id),
      session_id: request.session_id,
      payload: request.payload,
      opts: request.opts || %{},
      timeout_ms: timeout_ms
    }

    rpc_result = apply(rpc_module, :call, [node_name, remote_module, remote_function, [rpc_payload], timeout_ms])
    map_rpc_result(action, rpc_result, rpc_payload)
  rescue
    error ->
      {:error,
       %Error{
         code: :transport_error,
         message: "rpc transport failed",
         retryable: true,
         context: %{error: inspect(error), action: action}
       }}
  end

  defp map_rpc_result(_action, {:ok, payload}, request_payload) do
    {:ok, normalize_response(payload, request_payload)}
  end

  defp map_rpc_result(_action, {:error, reason}, _request_payload) do
    {:error, normalize_runtime_error(reason)}
  end

  defp map_rpc_result(_action, {:badrpc, :timeout}, _request_payload), do: timeout_error()
  defp map_rpc_result(_action, {:badrpc, {:timeout, _}}, _request_payload), do: timeout_error()

  defp map_rpc_result(_action, {:badrpc, reason}, _request_payload) do
    {:error,
     %Error{
       code: :transport_error,
       message: "rpc badrpc",
       retryable: true,
       context: %{reason: inspect(reason)}
     }}
  end

  defp map_rpc_result(_action, payload, _request_payload) do
    {:ok,
     %Response{
       runtime_id: @default_runtime_id,
       session_id: nil,
       payload: payload,
       metadata: %{}
     }}
  end

  defp normalize_response(%Response{} = response, _request_payload), do: response

  defp normalize_response(%{} = payload, request_payload) do
    %Response{
      runtime_id: normalize_runtime_id(Map.get(payload, :runtime_id) || Map.get(payload, "runtime_id") || request_payload.runtime_id),
      session_id: Map.get(payload, :session_id) || Map.get(payload, "session_id") || request_payload.session_id,
      payload: Map.get(payload, :payload, Map.get(payload, "payload")),
      metadata:
        payload
        |> Map.get(:metadata, Map.get(payload, "metadata", %{}))
        |> normalize_metadata()
    }
  end

  defp normalize_response(payload, request_payload) do
    %Response{
      runtime_id: request_payload.runtime_id,
      session_id: request_payload.session_id,
      payload: payload,
      metadata: %{}
    }
  end

  defp normalize_runtime_error(%Error{} = error), do: error

  defp normalize_runtime_error(%{code: code, message: message} = payload) do
    normalized_code = normalize_code(code)

    %Error{
      code: normalized_code,
      message: message,
      retryable: Map.get(payload, :retryable, retryable_code?(normalized_code)),
      context: Map.get(payload, :context, %{})
    }
  end

  defp normalize_runtime_error(%{"code" => code, "message" => message} = payload) do
    normalized_code = normalize_code(code)

    %Error{
      code: normalized_code,
      message: message,
      retryable: Map.get(payload, "retryable", retryable_code?(normalized_code)),
      context: Map.get(payload, "context", %{})
    }
  end

  defp normalize_runtime_error(reason) when reason in [:timeout, :rpc_timeout], do: timeout_error() |> elem(1)

  defp normalize_runtime_error(reason) do
    %Error{
      code: :runtime_error,
      message: "runtime rpc error",
      retryable: false,
      context: %{reason: inspect(reason)}
    }
  end

  defp timeout_error do
    {:error,
     %Error{
       code: :timeout,
       message: "runtime rpc timeout",
       retryable: true,
       context: %{}
     }}
  end

  defp resolve_remote_target(action, opts, config) do
    case Keyword.get(opts, :rpc_target) || Keyword.get(config, :rpc_target, %{}) do
      %{^action => {module, function}} ->
        {module, function}

      target when is_list(target) ->
        case Keyword.get(target, action) do
          {module, function} -> {module, function}
          _ -> default_target(action)
        end

      _ ->
        default_target(action)
    end
  end

  defp default_target(:open), do: {Gong.SessionManager, :open}
  defp default_target(:get), do: {Gong.SessionManager, :get}
  defp default_target(:prompt), do: {Gong.Session, :prompt}
  defp default_target(:close), do: {Gong.Session, :close}

  defp resolve_timeout(timeout_ms, opts, config) do
    timeout_ms || Keyword.get(opts, :timeout_ms) || Keyword.get(config, :rpc_timeout_ms, @default_timeout_ms)
  end

  defp normalize_runtime_id(value) when is_binary(value) and value != "", do: value
  defp normalize_runtime_id(_), do: @default_runtime_id

  defp normalize_code(code) when is_atom(code), do: code

  defp normalize_code(code) when is_binary(code) do
    code
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> case do
      "timeout" -> :timeout
      "session_not_found" -> :session_not_found
      "transport_error" -> :transport_error
      "runtime_error" -> :runtime_error
      "unsupported_operation" -> :unsupported_operation
      _ -> :runtime_error
    end
  end

  defp normalize_code(_), do: :runtime_error

  defp retryable_code?(code), do: code in [:timeout, :session_not_found, :transport_error]

  defp normalize_payload_text(payload) when is_binary(payload), do: payload
  defp normalize_payload_text(payload), do: to_string(payload)
  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp runtime_config, do: Application.get_env(:men, :runtime_bridge, [])
end
