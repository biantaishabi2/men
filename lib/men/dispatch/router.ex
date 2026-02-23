defmodule Men.Dispatch.Router do
  @moduledoc """
  dispatch 路由执行器：统一 cutover 决策、zcpg 调用与失败回退。
  """

  require Logger

  alias Men.Dispatch.CircuitBreaker
  alias Men.Gateway.SessionCoordinator

  @type route_result ::
          {:ok, %{text: binary(), meta: map()}, map()} | {:error, map(), map()} | {:ignore, map()}

  @spec execute(map(), map(), binary()) :: route_result()
  def execute(state, context, prompt)
      when is_map(state) and is_map(context) and is_binary(prompt) do
    decision = decide_route(state, context)

    case decision do
      :ignore ->
        {:ignore, state}

      :legacy ->
        execute_legacy(state, context, prompt)

      :zcpg ->
        execute_zcpg(state, context, prompt)
    end
  end

  defp decide_route(state, context) do
    policy = Map.get(state, :cutover_policy, Men.Dispatch.CutoverPolicy)

    policy.route(
      %{
        channel: Map.get(context, :channel),
        payload: Map.get(context, :payload),
        metadata: Map.get(context, :metadata, %{})
      },
      config: Map.get(state, :zcpg_cutover_config, [])
    )
  end

  defp execute_legacy(state, context, prompt) do
    case state.legacy_bridge_adapter.start_turn(prompt, bridge_context(context, state)) do
      {:ok, payload} -> {:ok, payload, state}
      {:error, error_payload} ->
        state = maybe_invalidate_runtime_session(state, context, error_payload)
        {:error, error_payload, state}
    end
  end

  defp execute_zcpg(state, context, prompt) do
    breaker = Map.get(state, :zcpg_breaker)

    case CircuitBreaker.allow?(breaker) do
      {:deny, breaker_after_deny} ->
        Logger.warning("dispatch.zcpg.breaker_open",
          request_id: context.request_id,
          run_id: context.run_id
        )

        state = %{state | zcpg_breaker: breaker_after_deny}
        execute_legacy(state, context, prompt)

      {:allow, breaker_after_allow} ->
        state = %{state | zcpg_breaker: breaker_after_allow}

        case state.zcpg_client.start_turn(prompt, bridge_context(context, state)) do
          {:ok, payload} ->
            breaker_after_success = CircuitBreaker.record_success(state.zcpg_breaker)
            state = %{state | zcpg_breaker: breaker_after_success}
            {:ok, mark_route(payload, :zcpg), state}

          {:error, error_payload} ->
            breaker_after_failure = CircuitBreaker.record_failure(state.zcpg_breaker)
            state = %{state | zcpg_breaker: breaker_after_failure}
            state = maybe_invalidate_runtime_session(state, context, error_payload)

            if fallback_required?(error_payload) do
              Logger.warning("dispatch.zcpg.fallback_to_legacy",
                request_id: context.request_id,
                run_id: context.run_id,
                code: Map.get(error_payload, :code)
              )

              case execute_legacy(state, context, prompt) do
                {:ok, payload, state_after_legacy} ->
                  {:ok, mark_route(payload, :legacy_fallback), state_after_legacy}

                {:error, legacy_error, state_after_legacy} ->
                  {:error, legacy_error, state_after_legacy}
              end
            else
              {:error, error_payload, state}
            end
        end
    end
  end

  defp fallback_required?(error_payload) when is_map(error_payload) do
    Map.get(error_payload, :fallback, false)
  end

  defp fallback_required?(_), do: false

  defp mark_route(%{meta: meta} = payload, route) when is_map(meta) do
    %{payload | meta: Map.put(meta, :dispatch_route, route)}
  end

  defp mark_route(%{} = payload, route) do
    Map.put(payload, :meta, %{dispatch_route: route})
  end

  defp bridge_context(context, state) do
    runtime_session_id = resolve_runtime_session_id(state, context.session_key)

    %{
      request_id: context.request_id,
      session_key: runtime_session_id,
      external_session_key: context.session_key,
      run_id: context.run_id
    }
    |> maybe_put_event_callback(state, context)
  end

  defp maybe_put_event_callback(context_map, %{streaming_enabled: true} = state, context) do
    Map.put(context_map, :event_callback, state.build_event_callback.(state, context))
  end

  defp maybe_put_event_callback(context_map, _state, _context), do: context_map

  defp resolve_runtime_session_id(%{session_coordinator_enabled: false}, session_key),
    do: session_key

  defp resolve_runtime_session_id(state, session_key) do
    case state.get_runtime_session_id.(state.session_coordinator_name, session_key) do
      {:ok, runtime_session_id} -> runtime_session_id
      {:error, _reason} -> session_key
    end
  end

  # runtime 返回会话失效错误时，清除本地映射，避免坏 session id 持续复用。
  defp maybe_invalidate_runtime_session(state, context, error_payload) do
    case invalidation_code(error_payload) do
      nil ->
        state

      code when state.session_coordinator_enabled ->
        reason = %{session_key: context.session_key, code: code}

        try do
          _ = SessionCoordinator.invalidate_by_session_key(state.session_coordinator_name, reason)
          state
        catch
          :exit, _ -> state
        end

      _code ->
        state
    end
  end

  defp invalidation_code(%{} = error_payload) do
    case Map.get(error_payload, :code) do
      code when code in [:session_not_found, "session_not_found"] -> :session_not_found
      code when code in [:runtime_session_not_found, "runtime_session_not_found"] -> :runtime_session_not_found
      _ -> nil
    end
  end

  defp invalidation_code(_), do: nil
end
