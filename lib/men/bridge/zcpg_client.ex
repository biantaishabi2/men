defmodule Men.Bridge.ZcpgClient do
  @moduledoc """
  zcpg 调用封装：统一超时、5xx 分类与错误映射。
  """

  require Logger

  alias Men.RuntimeBridge.{Request, Response, ZcpgRPC}

  @default_timeout_ms 8_000

  @type legacy_success :: {:ok, %{text: binary(), meta: map()}}
  @type legacy_error :: {:error, map()}

  @spec start_turn(binary(), map() | keyword()) :: legacy_success() | legacy_error()
  def start_turn(prompt, context) when is_binary(prompt) and is_list(context) do
    start_turn(prompt, Map.new(context))
  end

  def start_turn(prompt, context) when is_binary(prompt) and is_map(context) do
    start_ms = System.monotonic_time(:millisecond)
    timeout_ms = timeout_ms()

    request = %Request{
      runtime_id: "zcpg",
      session_id: map_value(context, :session_key, "unknown_session"),
      payload: prompt,
      timeout_ms: timeout_ms,
      opts: %{
        request_id: map_value(context, :request_id, "unknown_request"),
        run_id: map_value(context, :run_id, generate_run_id()),
        session_key: map_value(context, :session_key, "unknown_session"),
        tenant_id: map_value(context, :tenant_id, "default_tenant"),
        trace_id: map_value(context, :trace_id, map_value(context, :request_id, "unknown_request")),
        agent_id: map_value(context, :agent_id, "voucher_agent")
      }
    }

    result = ZcpgRPC.prompt(request, [])

    duration_ms = System.monotonic_time(:millisecond) - start_ms

    case result do
      {:ok, %Response{} = response} ->
        telemetry(:ok, duration_ms, %{timeout_ms: timeout_ms})

        {:ok,
         %{
           text: to_string(response.payload || ""),
           meta: Map.put(response.metadata || %{}, :source, :zcpg)
         }}

      {:error, error} ->
        mapped = normalize_error(error, request)

        Logger.warning("dispatch.zcpg_client.failed",
          request_id: request.opts.request_id,
          run_id: request.opts.run_id,
          code: mapped.code,
          fallback: mapped.fallback,
          details: inspect(mapped.details)
        )

        telemetry(:error, duration_ms, %{code: mapped.code, fallback: mapped.fallback})

        {:error,
         %{
           type: mapped.type,
           code: mapped.code,
           message: mapped.message,
           details: mapped.details,
           fallback: mapped.fallback
         }}
    end
  end

  def start_turn(_prompt, _context) do
    raise ArgumentError, "start_turn/2 expects prompt binary and context map/keyword"
  end

  defp normalize_error(%Men.RuntimeBridge.Error{} = error, request) do
    code = error.code |> normalize_code() |> Atom.to_string()

    %{
      type: if(error.code == :timeout, do: :timeout, else: :failed),
      code: code,
      message: error.message,
      details:
        (error.context || %{})
        |> Map.put(:request_id, request.opts.request_id)
        |> Map.put(:run_id, request.opts.run_id)
        |> Map.put(:session_key, request.opts.session_key),
      fallback: fallback_error?(error.code)
    }
  end

  defp normalize_error(other, request) do
    %{
      type: :failed,
      code: "runtime_error",
      message: "zcpg request failed",
      details: %{reason: inspect(other), request_id: request.opts.request_id},
      fallback: true
    }
  end

  defp fallback_error?(code) do
    normalize_code(code) in [:timeout, :transport_error, :runtime_error]
  end

  defp normalize_code(code) when is_atom(code), do: code

  defp normalize_code(code) when is_binary(code) do
    code
    |> String.downcase()
    |> String.to_atom()
  end

  defp normalize_code(_), do: :runtime_error

  defp telemetry(status, duration_ms, metadata) do
    :telemetry.execute(
      [:men, :dispatch, :zcpg, :request],
      %{duration_ms: duration_ms},
      Map.put(metadata, :status, status)
    )
  end

  defp timeout_ms do
    cfg = Application.get_env(:men, :zcpg_cutover, [])
    Keyword.get(cfg, :timeout_ms, @default_timeout_ms)
  end

  defp map_value(map, key, default) when is_map(map) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key), default)) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  defp generate_run_id do
    "run-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
