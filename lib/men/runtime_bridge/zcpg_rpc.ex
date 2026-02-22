defmodule Men.RuntimeBridge.ZcpgRPC do
  @moduledoc """
  基于 HTTP JSON v1 的 Runtime Bridge 适配器。
  """

  @behaviour Men.RuntimeBridge.Bridge

  alias Men.RuntimeBridge.{Error, Request, Response}

  @default_runtime_id "zcpg_rpc"
  @default_base_url "http://127.0.0.1:4015"
  @default_path "/v1/runtime/bridge/prompt"
  @default_timeout_ms 30_000

  defmodule HttpTransport do
    @moduledoc false
    @default_timeout_ms 30_000

    @callback request(
                :post,
                binary(),
                [{binary(), binary()}],
                binary(),
                keyword()
              ) :: {:ok, %{status: non_neg_integer(), body: term()}} | {:error, term()}

    @behaviour __MODULE__

    @impl true
    def request(:post, url, headers, body, opts) do
      finch_name = Keyword.get(opts, :finch, Men.Finch)
      timeout_ms = normalize_timeout(Keyword.get(opts, :timeout_ms, @default_timeout_ms))

      request = Finch.build(:post, url, headers, body)
      finch_opts = [receive_timeout: timeout_ms, pool_timeout: min(timeout_ms, 5_000)]

      case Finch.request(request, finch_name, finch_opts) do
        {:ok, %Finch.Response{status: status, body: response_body}} ->
          {:ok, %{status: status, body: response_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp normalize_timeout(value) when is_integer(value) and value > 0, do: value
    defp normalize_timeout(_), do: @default_timeout_ms
  end

  @impl true
  def prompt(%Request{} = request, opts \\ []) do
    with {:ok, cfg} <- build_config(request, opts),
         {:ok, payload} <- build_request_payload(request),
         {:ok, encoded_body} <- Jason.encode(payload),
         {:ok, %{status: status, body: body}} <- do_http_request(cfg, encoded_body),
         {:ok, text, meta} <- parse_response(status, body) do
      {:ok,
       %Response{
         runtime_id: normalize_runtime_id(request.runtime_id),
         session_id: request.session_id,
         payload: text,
         metadata: meta
       }}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         transport_error("zcpg rpc transport failed",
           reason: inspect(reason)
         )}
    end
  end

  @impl true
  def start_turn(prompt, context) when is_binary(prompt) and is_map(context) do
    request_id = context_value(context, :request_id, "unknown_request")
    session_key = context_value(context, :session_key, "unknown_session")
    run_id = context_value(context, :run_id, generate_run_id())
    runtime_id = context_value(context, :runtime_id, @default_runtime_id)

    request = %Request{
      runtime_id: runtime_id,
      session_id: session_key,
      payload: prompt,
      opts: %{
        request_id: request_id,
        session_key: session_key,
        run_id: run_id
      }
    }

    case prompt(request, []) do
      {:ok, %Response{} = response} ->
        {:ok,
         %{
           text: to_string(response.payload || ""),
           meta:
             response.metadata
             |> Map.put_new(:request_id, request_id)
             |> Map.put_new(:session_key, session_key)
             |> Map.put_new(:run_id, run_id)
         }}

      {:error, %Error{} = error} ->
        {:error,
         %{
           type: if(error.code == :timeout, do: :timeout, else: :failed),
           code: Atom.to_string(error.code),
           message: error.message,
           run_id: run_id,
           request_id: request_id,
           session_key: session_key,
           details: Map.put(error.context || %{}, :retryable, error.retryable)
         }}
    end
  end

  def start_turn(prompt, context) when is_binary(prompt) and is_list(context) do
    start_turn(prompt, Map.new(context))
  end

  def start_turn(_prompt, _context) do
    raise ArgumentError, "start_turn/2 expects prompt binary and context map/keyword"
  end

  defp build_config(%Request{} = request, opts) do
    cfg = Application.get_env(:men, __MODULE__, [])
    base_url = Keyword.get(cfg, :base_url, @default_base_url)
    path = Keyword.get(cfg, :path, @default_path)
    token = Keyword.get(cfg, :token)
    finch_name = Keyword.get(cfg, :finch, Men.Finch)
    transport = Keyword.get(opts, :transport) || Keyword.get(cfg, :transport, HttpTransport)
    timeout_ms = resolve_timeout(request, opts, cfg)

    request_opts =
      cfg
      |> Keyword.get(:request_opts, [])
      |> Keyword.put(:timeout_ms, timeout_ms)
      |> Keyword.put(:finch, finch_name)

    {:ok,
     %{
       url: build_url(base_url, path),
       headers: build_headers(token),
       transport: transport,
       request_opts: request_opts
     }}
  end

  defp build_headers(nil), do: [{"content-type", "application/json"}]
  defp build_headers(""), do: [{"content-type", "application/json"}]

  defp build_headers(token) do
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer " <> token}
    ]
  end

  defp resolve_timeout(%Request{} = request, opts, cfg) do
    request.timeout_ms ||
      Keyword.get(opts, :timeout_ms) ||
      Keyword.get(cfg, :timeout_ms) ||
      Keyword.get(cfg, :timeout) ||
      @default_timeout_ms
  end

  defp build_request_payload(%Request{} = request) do
    opts = request.opts || %{}

    request_id = map_value(opts, :request_id, "unknown_request")
    run_id = map_value(opts, :run_id, generate_run_id())
    session_key = request.session_id || map_value(opts, :session_key, "unknown_session")

    {:ok,
     %{
       request_id: request_id,
       session_key: session_key,
       run_id: run_id,
       prompt: normalize_prompt(request.payload)
     }}
  end

  defp normalize_prompt(payload) when is_binary(payload), do: payload
  defp normalize_prompt(nil), do: ""
  defp normalize_prompt(payload), do: to_string(payload)

  defp do_http_request(cfg, encoded_body) do
    case cfg.transport.request(:post, cfg.url, cfg.headers, encoded_body, cfg.request_opts) do
      {:ok, %{status: status, body: body}} ->
        {:ok, %{status: status, body: body}}

      {:error, reason} ->
        if timeout_reason?(reason) do
          {:error,
           timeout_error("zcpg rpc request timeout",
             reason: inspect(reason)
           )}
        else
          {:error,
           transport_error("zcpg rpc request failed",
             reason: inspect(reason)
           )}
        end
    end
  end

  # 统一按优先级映射：timeout/504 > 400/422/契约错误 > 5xx > 其他。
  defp parse_response(504, body) do
    {:error, timeout_error("zcpg rpc gateway timeout", status: 504, body: summarize_body(body))}
  end

  defp parse_response(status, body) when status in [400, 422] do
    {:error,
     invalid_argument_error(
       "zcpg rpc invalid argument",
       status: status,
       body: summarize_body(body)
     )}
  end

  defp parse_response(status, body) when status in 200..299 do
    with {:ok, decoded} <- decode_body(body),
         {:ok, text, meta} <- decode_success_payload(decoded) do
      {:ok, text, meta}
    else
      {:error, :invalid_json} ->
        {:error, invalid_argument_error("zcpg rpc invalid json body", body: summarize_body(body))}

      {:error, :invalid_body} ->
        {:error,
         invalid_argument_error("zcpg rpc response body must be map", body: inspect(body))}

      {:error, :missing_text} ->
        {:error,
         invalid_argument_error("zcpg rpc response missing text", body: summarize_body(body))}

      {:error, :invalid_meta} ->
        {:error,
         invalid_argument_error("zcpg rpc response meta must be map", body: summarize_body(body))}
    end
  end

  defp parse_response(status, body) when status in 500..599 do
    {:error,
     %Error{
       code: :runtime_error,
       message: "zcpg rpc upstream error status=#{status}",
       retryable: true,
       context: %{status: status, body: summarize_body(body)}
     }}
  end

  defp parse_response(status, body) do
    {:error,
     %Error{
       code: :transport_error,
       message: "zcpg rpc unexpected status=#{status}",
       retryable: true,
       context: %{status: status, body: summarize_body(body)}
     }}
  end

  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _} -> {:error, :invalid_body}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp decode_body(_), do: {:error, :invalid_body}

  defp decode_success_payload(%{} = body) do
    text = map_value(body, :text, nil)

    cond do
      not is_binary(text) ->
        {:error, :missing_text}

      true ->
        meta = map_value(body, :meta, %{})

        cond do
          is_nil(meta) -> {:ok, text, %{}}
          is_map(meta) -> {:ok, text, meta}
          true -> {:error, :invalid_meta}
        end
    end
  end

  defp timeout_reason?(reason) when reason in [:timeout, :etimedout], do: true
  defp timeout_reason?({:timeout, _}), do: true
  defp timeout_reason?({:error, :timeout}), do: true

  defp timeout_reason?(reason) when is_binary(reason) do
    String.contains?(String.downcase(reason), "timeout")
  end

  defp timeout_reason?(reason), do: String.contains?(String.downcase(inspect(reason)), "timeout")

  defp timeout_error(message, context) do
    %Error{
      code: :timeout,
      message: message,
      retryable: true,
      context: Map.put(Map.new(context), :source, :zcpg_rpc)
    }
  end

  defp invalid_argument_error(message, context) do
    %Error{
      code: :invalid_argument,
      message: message,
      retryable: false,
      context: Map.put(Map.new(context), :source, :zcpg_rpc)
    }
  end

  defp transport_error(message, context) do
    %Error{
      code: :transport_error,
      message: message,
      retryable: true,
      context: Map.put(Map.new(context), :source, :zcpg_rpc)
    }
  end

  defp summarize_body(body) when is_binary(body), do: body
  defp summarize_body(body), do: inspect(body)

  defp context_value(map, key, default) do
    map
    |> Map.get(key, Map.get(map, Atom.to_string(key), default))
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp build_url(base_url, path) do
    String.trim_trailing(base_url, "/") <> "/" <> String.trim_leading(path, "/")
  end

  defp normalize_runtime_id(runtime_id) when is_binary(runtime_id) and runtime_id != "",
    do: runtime_id

  defp normalize_runtime_id(_), do: @default_runtime_id

  defp generate_run_id do
    "run-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
