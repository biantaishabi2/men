defmodule Men.Gateway.DispatchServer do
  @moduledoc """
  Gateway 控制面主状态机：ingress -> route -> bridge -> egress。
  """

  use GenServer

  require Logger

  alias Men.Channels.Egress.Messages.{ErrorMessage, FinalMessage}
  alias Men.Gateway.Routing
  alias Men.Gateway.Types

  @type state :: %{
          bridge_adapter: module(),
          egress_adapter: module(),
          processed_run_ids: MapSet.t(binary())
        }

  defmodule NoopEgress do
    @moduledoc false
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

    {:ok,
     %{
       bridge_adapter: Keyword.get(opts, :bridge_adapter, Keyword.fetch!(config, :bridge_adapter)),
       egress_adapter: Keyword.get(opts, :egress_adapter, Keyword.fetch!(config, :egress_adapter)),
       processed_run_ids: MapSet.new()
     }}
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
         :ok <- log_stage(context, "ingress"),
         {:ok, route_result} <- Routing.resolve(context),
         :ok <- log_stage(context, "route"),
         bridge_result <- start_bridge_turn(state.bridge_adapter, context, route_result),
         {:ok, bridge_ok} <- ensure_bridge_ok(bridge_result),
         :ok <- log_stage(context, "bridge"),
         :ok <- send_final(state.egress_adapter, route_result.target, context, bridge_ok),
         :ok <- log_stage(context, "egress") do
      {ok_reply(context, bridge_ok), mark_processed(state, context.run_id)}
    else
      {:duplicate, _run_id} ->
        {{:ok, :duplicate}, state}

      {:bridge_failed, bridge_result, context, route_result} ->
        mapped = map_bridge_error(bridge_result)
        final_error = ensure_error_egress(state.egress_adapter, route_result.target, context, mapped)
        _ = log_stage(context, "bridge", %{error_code: final_error.code})
        {error_reply(context, final_error), maybe_mark_processed(state, context.run_id, final_error.code)}

      {:error, %{code: "egress_fail"} = mapped, context} ->
        _ = log_stage(context, "egress", %{error_code: mapped.code})
        {error_reply(context, mapped), state}

      {:error, reason} ->
        context = fallback_context(inbound_event)
        mapped = map_invalid_error(reason)
        _ = log_stage(context, "ingress", %{error_code: mapped.code})
        {error_reply(context, mapped), state}
    end
  end

  defp normalize_event(%{} = inbound_event) do
    with {:ok, request_id} <- fetch_required_binary(inbound_event, :request_id),
         {:ok, channel} <- fetch_required_binary(inbound_event, :channel),
         {:ok, event_type} <- fetch_required_binary(inbound_event, :event_type),
         {:ok, _user_id} <- fetch_present(inbound_event, :user_id),
         {:ok, payload} <- fetch_required_payload(inbound_event, :payload),
         {:ok, metadata} <- normalize_metadata(Map.get(inbound_event, :metadata)),
         {:ok, session_key} <- Routing.resolve_session_key(inbound_event),
         run_id <- normalize_run_id(Map.get(inbound_event, :run_id)) do
      {:ok,
       %{
         request_id: request_id,
         channel: channel,
         event_type: event_type,
         payload: payload,
         metadata: metadata,
         session_key: session_key,
         run_id: run_id,
         user_id: Map.get(inbound_event, :user_id),
         group_id: Map.get(inbound_event, :group_id),
         thread_id: Map.get(inbound_event, :thread_id)
       }}
    end
  end

  defp normalize_event(_), do: {:error, :invalid_event}

  defp start_bridge_turn(bridge_adapter, context, route_result) do
    bridge_context = %{
      request_id: context.request_id,
      session_key: context.session_key,
      run_id: context.run_id,
      channel: context.channel,
      event_type: context.event_type
    }

    case payload_to_prompt(context.payload) do
      {:ok, prompt} ->
        normalize_bridge_result(bridge_adapter.start_turn(prompt, bridge_context), context, route_result)

      {:error, _reason} ->
        %{
          status: :error,
          run_id: context.run_id,
          reason: "invalid payload",
          meta: %{}
        }
        |> attach_context(context, route_result)
    end
  end

  defp send_final(egress_adapter, target, context, bridge_ok) do
    message = %FinalMessage{
      session_key: context.session_key,
      content: bridge_ok.text,
      metadata:
        context.metadata
        |> Map.merge(%{
          "request_id" => context.request_id,
          "run_id" => context.run_id,
          "session_key" => context.session_key,
          "channel" => context.channel,
          "event_type" => context.event_type
        })
        |> Map.merge(Map.get(bridge_ok, :meta, %{}))
    }

    case egress_adapter.send(target, message) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         %{
           code: "egress_fail",
           reason: "egress send failed",
           details: %{reason: inspect(reason)}
         }, context}
    end
  end

  defp ensure_error_egress(egress_adapter, target, context, mapped_error) do
    message = %ErrorMessage{
      session_key: context.session_key,
      reason: mapped_error.reason,
      code: mapped_error.code,
      metadata:
        context.metadata
        |> Map.merge(%{
          "request_id" => context.request_id,
          "run_id" => context.run_id,
          "session_key" => context.session_key,
          "channel" => context.channel,
          "event_type" => context.event_type
        })
        |> Map.merge(mapped_error.metadata)
    }

    case egress_adapter.send(target, message) do
      :ok ->
        mapped_error

      {:error, reason} ->
        %{
          code: "egress_fail",
          reason: "egress send failed",
          metadata: %{"reason" => inspect(reason)}
        }
    end
  end

  defp ensure_bridge_ok(%{status: :ok} = result), do: {:ok, result}

  defp ensure_bridge_ok(%{status: _} = result),
    do: {:bridge_failed, result, result.context, result.route}

  defp normalize_bridge_result({:ok, payload}, context, route_result) when is_map(payload) do
    %{
      status: :ok,
      run_id: Map.get(payload, :run_id, context.run_id),
      text: Map.get(payload, :text, ""),
      meta: Map.get(payload, :meta, %{})
    }
    |> attach_context(context, route_result)
  end

  defp normalize_bridge_result({:error, payload}, context, route_result) when is_map(payload) do
    status =
      case Map.get(payload, :type) do
        :timeout -> :timeout
        _ -> :error
      end

    %{
      status: status,
      run_id: Map.get(payload, :run_id, context.run_id),
      reason: Map.get(payload, :message, "bridge error"),
      meta: Map.get(payload, :details, %{})
    }
    |> attach_context(context, route_result)
  end

  defp normalize_bridge_result(_, context, route_result) do
    %{
      status: :error,
      run_id: context.run_id,
      reason: "bridge invalid response",
      meta: %{}
    }
    |> attach_context(context, route_result)
  end

  defp attach_context(result, context, route_result) do
    result
    |> Map.put(:context, context)
    |> Map.put(:route, route_result)
  end

  defp map_bridge_error(%{status: :timeout, reason: reason, meta: meta}) do
    %{code: "bridge_timeout", reason: reason, metadata: stringify_map(meta)}
  end

  defp map_bridge_error(%{reason: reason, meta: meta}) do
    %{code: "bridge_error", reason: reason, metadata: stringify_map(meta)}
  end

  defp map_invalid_error(:signature_invalid) do
    %{code: "signature_invalid", reason: "signature invalid", metadata: %{}}
  end

  defp map_invalid_error(reason) do
    %{code: "bridge_error", reason: "invalid inbound event", metadata: %{"reason" => inspect(reason)}}
  end

  defp ok_reply(context, bridge_ok) do
    {:ok,
     %{
       session_key: context.session_key,
       run_id: context.run_id,
       request_id: context.request_id,
       payload: %{text: bridge_ok.text, meta: bridge_ok.meta},
       metadata: context.metadata
     }}
  end

  defp error_reply(context, mapped_error) do
    {:error,
     %{
       session_key: context.session_key,
       run_id: context.run_id,
       request_id: context.request_id,
       reason: mapped_error.reason,
       code: mapped_error.code,
       metadata: mapped_error.metadata
     }}
  end

  defp payload_to_prompt(payload) when is_binary(payload), do: {:ok, payload}

  defp payload_to_prompt(payload) do
    case Jason.encode(payload) do
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_run_id(run_id) when is_binary(run_id) and run_id != "", do: run_id
  defp normalize_run_id(_), do: "run-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

  defp fetch_required_binary(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_required_payload(attrs, key) do
    if Map.has_key?(attrs, key), do: {:ok, Map.get(attrs, key)}, else: {:error, {:missing_field, key}}
  end

  defp fetch_present(attrs, key) do
    if Map.has_key?(attrs, key), do: {:ok, Map.get(attrs, key)}, else: {:error, {:missing_field, key}}
  end

  defp normalize_metadata(nil), do: {:ok, %{}}
  defp normalize_metadata(%{} = metadata), do: {:ok, metadata}
  defp normalize_metadata(_), do: {:error, {:invalid_field, :metadata}}

  defp ensure_not_duplicate(run_id, state) do
    if MapSet.member?(state.processed_run_ids, run_id), do: {:duplicate, run_id}, else: :ok
  end

  defp mark_processed(state, run_id) do
    %{state | processed_run_ids: MapSet.put(state.processed_run_ids, run_id)}
  end

  defp maybe_mark_processed(state, _run_id, "egress_fail"), do: state
  defp maybe_mark_processed(state, run_id, _code), do: mark_processed(state, run_id)

  defp stringify_map(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_map(_), do: %{}

  defp fallback_context(%{} = inbound_event) do
    %{
      request_id: Map.get(inbound_event, :request_id, "unknown_request"),
      channel: to_string(Map.get(inbound_event, :channel, "unknown_channel")),
      event_type: to_string(Map.get(inbound_event, :event_type, "unknown_event")),
      session_key: Map.get(inbound_event, :session_key, "unknown_session"),
      run_id: Map.get(inbound_event, :run_id, "unknown_run"),
      metadata: %{}
    }
  end

  defp fallback_context(_inbound_event) do
    %{
      request_id: "unknown_request",
      channel: "unknown_channel",
      event_type: "unknown_event",
      session_key: "unknown_session",
      run_id: "unknown_run",
      metadata: %{}
    }
  end

  defp log_stage(context, stage, extra \\ %{}) do
    whitelist =
      Application.get_env(:men, :gateway_log_fields, [
        :request_id,
        :session_key,
        :run_id,
        :channel,
        :event_type,
        :stage
      ])

    base = %{
      request_id: context.request_id,
      session_key: context.session_key,
      run_id: context.run_id,
      channel: context.channel,
      event_type: context.event_type,
      stage: stage
    }

    metadata =
      base
      |> Map.merge(extra)
      |> Enum.filter(fn {k, _v} -> k in whitelist end)

    Logger.info("gateway.dispatch", metadata)
    :ok
  end
end
