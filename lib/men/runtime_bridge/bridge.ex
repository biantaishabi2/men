defmodule Men.RuntimeBridge.Bridge do
  @moduledoc """
  Runtime Bridge 契约。

  兼容两条调用路径：
  - `call/2`: 结构体请求/响应契约（L0 基础契约）
  - `start_turn/2`: GongCLI 统一语义契约（运行时桥接）
  """

  alias Men.RuntimeBridge.{Error, ErrorResponse, Request, Response, TaskctlAdapter}
  alias Men.Gateway.Runtime.GraphContract

  @type error_type :: :failed | :timeout | :overloaded

  @type error_payload :: %{
          type: error_type(),
          code: binary(),
          message: binary(),
          run_id: binary(),
          request_id: binary(),
          session_key: binary(),
          details: map() | nil
        }

  @type success_payload :: %{
          text: binary(),
          meta: map()
        }

  @typedoc """
  start_turn/2 第二个参数使用的追踪上下文。
  """
  @type turn_context :: %{
          optional(:request_id) => binary(),
          optional(:session_key) => binary(),
          optional(:run_id) => binary(),
          optional(:runtime_id) => binary()
        }

  @callback open(Request.t(), opts :: keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  @callback get(Request.t(), opts :: keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  @callback prompt(Request.t(), opts :: keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  @callback close(Request.t(), opts :: keyword()) :: {:ok, Response.t()} | {:error, Error.t()}

  @callback call(Request.t(), opts :: keyword()) ::
              {:ok, Response.t()} | {:error, ErrorResponse.t()}

  @callback start_turn(prompt :: binary(), context :: turn_context()) ::
              {:ok, success_payload()} | {:error, error_payload()}

  @optional_callbacks open: 2, get: 2, prompt: 2, close: 2, call: 2, start_turn: 2

  @default_runtime_id "gong"

  @spec open(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def open(%Request{} = request, opts \\ []) do
    invoke_atomic(:open, request, opts)
  end

  @spec get(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def get(%Request{} = request, opts \\ []) do
    invoke_atomic(:get, request, opts)
  end

  @spec prompt(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def prompt(%Request{} = request, opts \\ []) do
    adapter = resolve_adapter(opts)

    if adapter_exports?(adapter, :prompt, 2) do
      case adapter.prompt(request, opts) do
        {:ok, %Response{} = response} ->
          {:ok, response}

        {:error, %Error{} = error} ->
          {:error, error}

        other ->
          {:error, normalize_legacy_error(other)}
      end
    else
      prompt_via_legacy(adapter, request, opts)
    end
  end

  @spec close(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def close(%Request{} = request, opts \\ []) do
    adapter = resolve_adapter(opts)

    if adapter_exports?(adapter, :close, 2) do
      case adapter.close(request, opts) do
        {:ok, %Response{} = response} ->
          {:ok, response}

        {:error, %Error{code: :session_not_found} = error} ->
          {:ok, idempotent_close_response(request, error)}

        {:error, %Error{} = error} ->
          {:error, error}

        other ->
          case normalize_legacy_error(other) do
            %Error{code: :session_not_found} = error ->
              {:ok, idempotent_close_response(request, error)}

            %Error{} = error ->
              {:error, error}
          end
      end
    else
      {:error, unsupported_error("adapter does not implement close/2")}
    end
  end

  @spec call(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, ErrorResponse.t()}
  def call(%Request{} = request, opts \\ []) do
    adapter = resolve_adapter(opts)

    if bridge_v1_enabled?(opts) do
      case prompt(request, opts) do
        {:ok, %Response{} = response} ->
          {:ok, response}

        {:error, %Error{} = error} ->
          {:error, error_to_error_response(request, error)}
      end
    else
      if adapter_exports?(adapter, :call, 2) do
        adapter.call(request, opts)
      else
        {:error,
         %ErrorResponse{
           session_key: normalize_session_key(request),
           code: "unsupported_operation",
           reason: "adapter does not implement call/2",
           metadata: %{adapter: inspect(adapter)}
         }}
      end
    end
  end

  @spec start_turn(binary(), turn_context() | keyword(), keyword()) ::
          {:ok, success_payload()} | {:error, error_payload()}
  def start_turn(prompt, context, opts \\ [])

  def start_turn(prompt, context, opts) when is_binary(prompt) and is_list(context) do
    start_turn(prompt, Map.new(context), opts)
  end

  def start_turn(prompt, context, opts) when is_binary(prompt) and is_map(context) do
    adapter = resolve_adapter(opts)

    if bridge_v1_enabled?(opts) do
      request = context_to_request(prompt, context)

      case prompt(request, opts) do
        {:ok, %Response{} = response} ->
          {:ok,
           %{
             text: to_string(response.payload || ""),
             meta:
               response.metadata
               |> normalize_meta()
               |> Map.put_new(:request_id, context_value(context, :request_id, "unknown_request"))
               |> Map.put_new(:session_key, context_value(context, :session_key, "unknown_session"))
               |> Map.put_new(:run_id, context_value(context, :run_id, generate_run_id()))
           }}

        {:error, %Error{} = error} ->
          {:error, error_to_legacy_payload(context, error)}
      end
    else
      if adapter_exports?(adapter, :start_turn, 2) do
        adapter.start_turn(prompt, context)
      else
        {:error,
         %{
           type: :failed,
           code: "unsupported_operation",
           message: "adapter does not implement start_turn/2",
           run_id: context_value(context, :run_id, "unknown_run"),
           request_id: context_value(context, :request_id, "unknown_request"),
           session_key: context_value(context, :session_key, "unknown_session"),
           details: %{adapter: inspect(adapter)}
         }}
      end
    end
  end

  def start_turn(_prompt, _context, _opts) do
    raise ArgumentError, "start_turn/2 expects prompt binary and context map/keyword"
  end

  @spec graph(GraphContract.action() | String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, ErrorResponse.t()}
  def graph(action, payload, opts \\ []) do
    graph_adapter = opts[:graph_adapter] || config(:graph_adapter, TaskctlAdapter)
    graph_adapter.run(action, payload, opts)
  end

  defp config(key, default) do
    :men
    |> Application.get_env(:runtime_bridge, [])
    |> Keyword.get(key, default)
  end

  defp resolve_adapter(opts) do
    Keyword.get(opts, :adapter, config(:bridge_impl, Men.RuntimeBridge.GongCLI))
  end

  defp bridge_v1_enabled?(opts) do
    Keyword.get(opts, :bridge_v1_enabled, config(:bridge_v1_enabled, false))
  end

  defp invoke_atomic(fun, %Request{} = request, opts) do
    adapter = resolve_adapter(opts)

    if adapter_exports?(adapter, fun, 2) do
      apply(adapter, fun, [request, opts])
    else
      {:error, unsupported_error("adapter does not implement #{fun}/2")}
    end
  end

  defp prompt_via_legacy(adapter, %Request{} = request, _opts) do
    if adapter_exports?(adapter, :start_turn, 2) do
      prompt = normalize_prompt(request)
      context = request_to_context(request)

      case adapter.start_turn(prompt, context) do
        {:ok, %{text: text} = payload} ->
          {:ok,
           %Response{
             runtime_id: request.runtime_id,
             session_id: request.session_id,
             payload: text,
             metadata: payload |> Map.get(:meta, %{}) |> normalize_meta()
           }}

        other ->
          {:error, normalize_legacy_error(other)}
      end
    else
      {:error, unsupported_error("adapter does not implement prompt/2")}
    end
  end

  defp normalize_prompt(%Request{} = request) do
    cond do
      is_binary(request.payload) -> request.payload
      is_binary(request.content) -> request.content
      is_nil(request.payload) -> ""
      true -> to_string(request.payload)
    end
  end

  defp request_to_context(%Request{} = request) do
    opts = request.opts || %{}

    %{
      request_id: map_value(opts, :request_id, "unknown_request"),
      session_key: normalize_session_key(request),
      run_id: map_value(opts, :run_id, generate_run_id()),
      runtime_id: request.runtime_id || @default_runtime_id
    }
  end

  defp context_to_request(prompt, context) do
    session_key = context_value(context, :session_key, "unknown_session")
    request_id = context_value(context, :request_id, "unknown_request")
    run_id = context_value(context, :run_id, generate_run_id())

    %Request{
      runtime_id: context_value(context, :runtime_id, @default_runtime_id),
      session_id: session_key,
      payload: prompt,
      opts: %{
        request_id: request_id,
        session_key: session_key,
        run_id: run_id
      }
    }
  end

  defp normalize_legacy_error({:error, %Error{} = error}), do: error

  defp normalize_legacy_error({:error, payload}) when is_map(payload) do
    details = map_value(payload, :details, %{}) |> normalize_map()
    raw_code = map_value(payload, :code, "runtime_error")
    code = normalize_error_code(raw_code, details)
    retryable = normalize_retryable(code, details)

    %Error{
      code: code,
      message: map_value(payload, :message, "runtime bridge failed"),
      retryable: retryable,
      context: details
    }
  end

  defp normalize_legacy_error(other) do
    %Error{
      code: :runtime_error,
      message: "runtime bridge failed",
      retryable: false,
      context: %{raw: inspect(other)}
    }
  end

  defp normalize_error_code(raw_code, details) do
    status = map_value(details, :status, nil)

    cond do
      timeout_status?(status) -> :timeout
      status in [400, 422] -> :invalid_argument
      is_integer(status) and status >= 500 -> :runtime_error
      true -> code_from_raw(raw_code)
    end
  end

  defp code_from_raw(raw_code) when is_atom(raw_code) do
    case raw_code do
      :session_not_found -> :session_not_found
      :runtime_session_not_found -> :session_not_found
      :timeout -> :timeout
      :invalid_argument -> :invalid_argument
      :transport_error -> :transport_error
      :runtime_error -> :runtime_error
      _ -> :runtime_error
    end
  end

  defp code_from_raw(raw_code) when is_binary(raw_code) do
    case String.downcase(raw_code) do
      "session_not_found" -> :session_not_found
      "runtime_session_not_found" -> :session_not_found
      "timeout" -> :timeout
      "invalid_argument" -> :invalid_argument
      "transport_error" -> :transport_error
      "runtime_error" -> :runtime_error
      _ -> :runtime_error
    end
  end

  defp code_from_raw(_), do: :runtime_error

  defp normalize_retryable(code, details) do
    explicit = map_value(details, :retryable, :not_set)

    if is_boolean(explicit) do
      explicit
    else
      case code do
        :invalid_argument -> false
        :session_not_found -> true
        :timeout -> true
        :transport_error -> true
        :runtime_error -> true
        _ -> false
      end
    end
  end

  defp error_to_error_response(%Request{} = request, %Error{} = error) do
    %ErrorResponse{
      session_key: normalize_session_key(request),
      code: Atom.to_string(error.code),
      reason: normalize_reason(error.message),
      metadata: %{retryable: error.retryable, context: error.context}
    }
  end

  defp error_to_legacy_payload(context, %Error{} = error) do
    %{
      type: if(error.code == :timeout, do: :timeout, else: :failed),
      code: Atom.to_string(error.code),
      message: error.message,
      run_id: context_value(context, :run_id, "unknown_run"),
      request_id: context_value(context, :request_id, "unknown_request"),
      session_key: context_value(context, :session_key, "unknown_session"),
      details: Map.put(error.context || %{}, :retryable, error.retryable)
    }
  end

  defp idempotent_close_response(%Request{} = request, _error) do
    %Response{
      runtime_id: request.runtime_id,
      session_id: request.session_id,
      payload: :closed,
      metadata: %{idempotent: true, reason: :session_not_found}
    }
  end

  defp unsupported_error(message) do
    %Error{code: :runtime_error, message: message, retryable: false, context: %{}}
  end

  defp timeout_status?(504), do: true
  defp timeout_status?(_), do: false

  defp normalize_reason(message) when is_binary(message), do: message
  defp normalize_reason(message), do: inspect(message)

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: %{}

  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_), do: %{}

  defp normalize_session_key(%Request{} = request) do
    request.session_key || request.session_id || "unknown_session"
  end

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_value(_map, _key, default), do: default

  defp context_value(context, key, default) when is_map(context) do
    Map.get(context, key, Map.get(context, Atom.to_string(key), default))
  end

  defp generate_run_id do
    "run_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 16)
  end

  defp adapter_exports?(adapter, fun, arity) when is_atom(adapter) do
    case Code.ensure_loaded(adapter) do
      {:module, _} -> function_exported?(adapter, fun, arity)
      {:error, _} -> false
    end
  end
end
