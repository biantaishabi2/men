defmodule Men.RuntimeBridge.Bridge do
  @moduledoc """
  RuntimeBridge 契约层。

  v1 原子接口：`open/2` `get/2` `prompt/2` `close/2`。
  兼容入口：`call/2` `start_turn/2`（deprecated）。

  兼容层默认走旧路径，开启 `:bridge_v1_enabled` 后可灰度切到新路径。
  """

  alias Men.RuntimeBridge.{Error, ErrorResponse, Request, Response}

  @type result :: {:ok, Response.t()} | {:error, Error.t()}

  @typedoc """
  start_turn/2 兼容入口上下文。
  """
  @type turn_context :: %{
          optional(:request_id) => binary(),
          optional(:session_key) => binary(),
          optional(:external_session_key) => binary(),
          optional(:runtime_id) => binary(),
          optional(:run_id) => binary()
        }

  @callback open(Request.t(), opts :: keyword()) :: result()
  @callback get(Request.t(), opts :: keyword()) :: result()
  @callback prompt(Request.t(), opts :: keyword()) :: result()
  @callback close(Request.t(), opts :: keyword()) :: result()

  @callback call(Request.t(), opts :: keyword()) :: {:ok, Response.t()} | {:error, ErrorResponse.t()}
  @callback start_turn(prompt :: binary(), context :: turn_context()) ::
              {:ok, %{text: binary(), meta: map()}} | {:error, map()}

  @optional_callbacks open: 2, get: 2, prompt: 2, close: 2, call: 2, start_turn: 2

  @default_runtime_id "gong"

  @spec open(Request.t(), keyword()) :: result()
  def open(%Request{} = request, opts \\ []), do: invoke_new(:open, request, opts)

  @spec get(Request.t(), keyword()) :: result()
  def get(%Request{} = request, opts \\ []), do: invoke_new(:get, request, opts)

  @spec prompt(Request.t(), keyword()) :: result()
  def prompt(%Request{} = request, opts \\ []), do: invoke_new(:prompt, request, opts)

  @spec close(Request.t(), keyword()) :: result()
  def close(%Request{} = request, opts \\ []), do: invoke_new(:close, request, opts)

  @deprecated "请改用 open/get/prompt/close"
  @spec call(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, ErrorResponse.t()}
  def call(%Request{} = request, opts \\ []) do
    adapter = resolve_adapter(opts)

    cond do
      use_v1_bridge_path?(opts) ->
        case prompt(request, opts) do
          {:ok, %Response{} = response} ->
            {:ok, response}

          {:error, %Error{} = error} ->
            {:error, to_legacy_error_response(error, request)}
        end

      function_exported?(adapter, :call, 2) ->
        adapter.call(request, opts)

      true ->
        {:error,
         %ErrorResponse{
           session_key: request.session_id || "unknown_session",
           reason: "adapter does not implement call/2",
           code: "unsupported_operation",
           metadata: %{adapter: inspect(adapter), action: :call}
         }}
    end
  end

  @deprecated "请改用 open/get/prompt/close"
  @spec start_turn(binary(), map() | keyword(), keyword()) ::
          {:ok, %{text: binary(), meta: map()}} | {:error, map()}
  def start_turn(prompt_text, context, opts \\ [])
      when is_binary(prompt_text) and (is_map(context) or is_list(context)) do
    adapter = resolve_adapter(opts)
    context_map = if is_map(context), do: context, else: Map.new(context)

    cond do
      use_v1_bridge_path?(opts) ->
        context_to_request(prompt_text, context_map, opts)
        |> prompt(opts)
        |> to_legacy_start_turn_result(prompt_text, context_map)

      function_exported?(adapter, :start_turn, 2) ->
        adapter.start_turn(prompt_text, context_map)

      true ->
        context_to_request(prompt_text, context_map, opts)
        |> prompt(opts)
        |> to_legacy_start_turn_result(prompt_text, context_map)
    end
  end

  defp invoke_new(action, %Request{} = request, opts) do
    adapter = resolve_adapter(opts)

    cond do
      function_exported?(adapter, action, 2) ->
        adapter
        |> apply(action, [request, opts])
        |> normalize_result(request)

      action == :prompt and function_exported?(adapter, :start_turn, 2) ->
        request
        |> prompt_to_legacy_context()
        |> then(fn {prompt_text, context} ->
          adapter.start_turn(prompt_text, context)
        end)
        |> normalize_start_turn_result(request)

      action == :close ->
        {:ok,
         %Response{
           runtime_id: request.runtime_id,
           session_id: request.session_id,
           payload: :closed,
           metadata: %{source: :bridge_noop_close}
         }}

      true ->
        {:error,
         %Error{
           code: :unsupported_operation,
           message: "adapter does not implement #{action}/2",
           retryable: false,
           context: %{adapter: inspect(adapter), action: action}
         }}
    end
  end

  defp normalize_result({:ok, %Response{} = response}, _request), do: {:ok, response}
  defp normalize_result({:error, %Error{} = error}, _request), do: {:error, error}

  defp normalize_result({:error, %ErrorResponse{} = error}, _request) do
    {:error,
     %Error{
       code: normalize_code(error.code || :runtime_error),
       message: error.reason,
       retryable: retryable?(error.code),
       context: Map.put(error.metadata || %{}, :session_key, error.session_key)
     }}
  end

  defp normalize_result(other, request) do
    {:error,
     %Error{
       code: :runtime_error,
       message: "invalid runtime bridge result",
       retryable: false,
       context: %{result: inspect(other), request: inspect(request)}
     }}
  end

  defp normalize_start_turn_result({:ok, %{text: text, meta: meta}}, request)
       when is_binary(text) and is_map(meta) do
    {:ok,
     %Response{
       runtime_id: request.runtime_id,
       session_id: request.session_id,
       payload: text,
       metadata: meta
     }}
  end

  defp normalize_start_turn_result({:error, error_payload}, _request) when is_map(error_payload) do
    code = error_payload |> Map.get(:code, :runtime_error) |> normalize_code()

    {:error,
     %Error{
       code: code,
       message: Map.get(error_payload, :message, "runtime bridge failed"),
       retryable: retryable?(code),
       context: Map.get(error_payload, :details, %{})
     }}
  end

  defp normalize_start_turn_result(other, request), do: normalize_result(other, request)

  defp to_legacy_error_response(%Error{} = error, %Request{} = request) do
    %ErrorResponse{
      session_key: request.session_id || "unknown_session",
      reason: error.message,
      code: Atom.to_string(error.code),
      metadata: error.context
    }
  end

  defp to_legacy_start_turn_result({:ok, %Response{} = response}, _prompt_text, context_map) do
    text = response.payload |> normalize_prompt_payload()

    {:ok,
     %{
       text: text,
       meta:
         response.metadata
         |> Map.put_new(:runtime_id, response.runtime_id)
         |> Map.put_new(:session_key, response.session_id || Map.get(context_map, :session_key))
     }}
  end

  defp to_legacy_start_turn_result({:error, %Error{} = error}, _prompt_text, context_map) do
    {:error,
     %{
       type: :failed,
       code: Atom.to_string(error.code),
       message: error.message,
       run_id: Map.get(context_map, :run_id),
       request_id: Map.get(context_map, :request_id),
       session_key: Map.get(context_map, :session_key),
       details: error.context
     }}
  end

  defp context_to_request(prompt_text, context_map, opts) do
    runtime_id =
      context_map
      |> Map.get(:runtime_id)
      |> normalize_runtime_id()

    session_id =
      Map.get(context_map, :session_id) ||
        Map.get(context_map, :session_key) ||
        Map.get(context_map, "session_id") ||
        Map.get(context_map, "session_key")

    %Request{
      runtime_id: runtime_id,
      session_id: session_id,
      payload: prompt_text,
      opts: Map.drop(context_map, [:runtime_id, :session_id, :session_key]),
      timeout_ms: resolve_timeout(nil, opts)
    }
  end

  defp prompt_to_legacy_context(%Request{} = request) do
    prompt_text = normalize_prompt_payload(request.payload)

    context =
      request.opts
      |> maybe_put(:session_key, request.session_id)
      |> maybe_put(:runtime_id, request.runtime_id)

    {prompt_text, context}
  end

  defp normalize_prompt_payload(payload) when is_binary(payload), do: payload
  defp normalize_prompt_payload(payload), do: to_string(payload)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_runtime_id(value) when is_binary(value) and value != "", do: value
  defp normalize_runtime_id(_), do: @default_runtime_id

  defp resolve_adapter(opts) do
    Keyword.get(opts, :adapter) ||
      runtime_config()[:bridge_impl] ||
      dispatch_server_config()[:bridge_adapter] ||
      Men.RuntimeBridge.GongCLI
  end

  defp use_v1_bridge_path?(opts) do
    case Keyword.fetch(opts, :bridge_v1_enabled) do
      {:ok, value} -> value == true
      :error -> runtime_config()[:bridge_v1_enabled] == true
    end
  end

  defp resolve_timeout(timeout_ms, opts) do
    timeout_ms || Keyword.get(opts, :timeout_ms) || runtime_config()[:timeout_ms]
  end

  defp runtime_config, do: Application.get_env(:men, :runtime_bridge, [])
  defp dispatch_server_config, do: Application.get_env(:men, Men.Gateway.DispatchServer, [])

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

  defp retryable?(code) do
    normalize_code(code) in [:timeout, :session_not_found, :transport_error]
  end
end
