defmodule Men.Gateway.TaskDispatcher do
  @moduledoc """
  Gateway 调度投递器：负责触发事件封装、去重、并发控制与背压。
  """

  use GenServer

  require Logger

  alias Men.Gateway.EventBus

  @default_topic "gateway_events"
  @default_dedup_ttl_ms :timer.minutes(5)
  @default_max_concurrency 100

  @type dispatch_request :: %{
          required(:schedule_id) => binary(),
          optional(:schedule_type) => atom() | binary(),
          optional(:fire_time) => DateTime.t() | binary() | integer(),
          optional(:idempotency_key) => binary(),
          optional(:metadata) => map()
        }

  @type state :: %{
          event_bus_topic: binary(),
          max_concurrency: pos_integer(),
          dedup_ttl_ms: pos_integer(),
          inflight: non_neg_integer(),
          recent_keys: %{optional(binary()) => non_neg_integer()},
          publish_fun: (binary(), map() -> :ok | term()),
          clock: (-> DateTime.t()),
          dropped_count: non_neg_integer(),
          dispatched_count: non_neg_integer(),
          duplicate_count: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec dispatch(GenServer.server(), dispatch_request()) :: :ok
  def dispatch(server \\ __MODULE__, request) when is_map(request) do
    GenServer.cast(server, {:dispatch, request})
  end

  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:men, __MODULE__, [])

    state = %{
      event_bus_topic: event_bus_topic(opts, config),
      max_concurrency:
        opts
        |> Keyword.get(
          :max_concurrency,
          Keyword.get(config, :max_concurrency, @default_max_concurrency)
        )
        |> normalize_positive_integer(@default_max_concurrency),
      dedup_ttl_ms:
        opts
        |> Keyword.get(:dedup_ttl_ms, Keyword.get(config, :dedup_ttl_ms, @default_dedup_ttl_ms))
        |> normalize_positive_integer(@default_dedup_ttl_ms),
      inflight: 0,
      recent_keys: %{},
      publish_fun:
        Keyword.get(
          opts,
          :publish_fun,
          Keyword.get(config, :publish_fun, &EventBus.publish_schedule_trigger/2)
        ),
      clock: Keyword.get(opts, :clock, Keyword.get(config, :clock, &DateTime.utc_now/0)),
      dropped_count: 0,
      dispatched_count: 0,
      duplicate_count: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:dispatch, request}, state) do
    now = now_utc(state.clock)
    now_ms = DateTime.to_unix(now, :millisecond)
    state = prune_recent_keys(state, now_ms)

    case normalize_request(request, now) do
      {:ok, normalized_request} ->
        {:noreply, maybe_dispatch(normalized_request, now, now_ms, state)}

      {:error, reason} ->
        Logger.warning("task dispatch ignored: #{inspect(reason)}")
        emit_telemetry(:invalid, %{reason: inspect(reason)})
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      inflight: state.inflight,
      dedup_size: map_size(state.recent_keys),
      dropped_count: state.dropped_count,
      dispatched_count: state.dispatched_count,
      duplicate_count: state.duplicate_count,
      max_concurrency: state.max_concurrency
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:dispatch_done, idempotency_key, publish_result}, state)
      when is_binary(idempotency_key) do
    next_state = %{state | inflight: max(state.inflight - 1, 0)}

    case publish_result do
      :ok ->
        emit_telemetry(:published, %{idempotency_key: idempotency_key})

      other ->
        Logger.warning("task dispatch publish returned non-ok: #{inspect(other)}")

        emit_telemetry(:publish_failed, %{
          idempotency_key: idempotency_key,
          reason: inspect(other)
        })
    end

    {:noreply, next_state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # 在独立任务里发布事件，避免阻塞 DispatchServer 主流程。
  defp maybe_dispatch(request, now, now_ms, state) do
    idempotency_key = request.idempotency_key

    cond do
      Map.has_key?(state.recent_keys, idempotency_key) ->
        emit_telemetry(:duplicate, %{
          idempotency_key: idempotency_key,
          schedule_id: request.schedule_id
        })

        %{state | duplicate_count: state.duplicate_count + 1}

      state.inflight >= state.max_concurrency ->
        Logger.warning(
          "task dispatch dropped by backpressure: schedule_id=#{request.schedule_id} inflight=#{state.inflight} max=#{state.max_concurrency}"
        )

        emit_telemetry(:dropped, %{schedule_id: request.schedule_id, inflight: state.inflight})
        %{state | dropped_count: state.dropped_count + 1}

      true ->
        event_payload = %{
          schedule_id: request.schedule_id,
          fire_time: DateTime.to_iso8601(request.fire_time),
          idempotency_key: idempotency_key,
          schedule_type: request.schedule_type,
          triggered_at: DateTime.to_iso8601(now),
          metadata: request.metadata
        }

        parent = self()
        publish_fun = state.publish_fun
        event_bus_topic = state.event_bus_topic

        Task.start(fn ->
          publish_result =
            try do
              publish_fun.(event_bus_topic, event_payload)
            rescue
              error ->
                {:error, error}
            end

          send(parent, {:dispatch_done, idempotency_key, publish_result})
        end)

        emit_telemetry(:accepted, %{
          schedule_id: request.schedule_id,
          inflight: state.inflight + 1
        })

        %{
          state
          | inflight: state.inflight + 1,
            recent_keys: Map.put(state.recent_keys, idempotency_key, now_ms),
            dispatched_count: state.dispatched_count + 1
        }
    end
  end

  defp normalize_request(request, now) when is_map(request) do
    with {:ok, schedule_id} <- normalize_schedule_id(request),
         {:ok, fire_time} <- normalize_fire_time(fetch_value(request, :fire_time), now) do
      schedule_type = normalize_schedule_type(fetch_value(request, :schedule_type))
      fire_time_iso = DateTime.to_iso8601(fire_time)

      {:ok,
       %{
         schedule_id: schedule_id,
         schedule_type: schedule_type,
         fire_time: fire_time,
         idempotency_key:
           normalize_idempotency_key(
             fetch_value(request, :idempotency_key),
             schedule_id,
             fire_time_iso
           ),
         metadata: normalize_metadata(request)
       }}
    end
  end

  defp normalize_request(_, _now), do: {:error, :invalid_request}

  defp normalize_schedule_id(request) do
    case fetch_value(request, :schedule_id) do
      schedule_id when is_binary(schedule_id) and schedule_id != "" -> {:ok, schedule_id}
      _ -> {:error, :invalid_schedule_id}
    end
  end

  defp normalize_fire_time(nil, now), do: {:ok, now}

  defp normalize_fire_time(%DateTime{} = fire_time, _now),
    do: {:ok, DateTime.shift_zone!(fire_time, "Etc/UTC")}

  defp normalize_fire_time(fire_time, _now) when is_binary(fire_time) do
    case DateTime.from_iso8601(fire_time) do
      {:ok, datetime, _offset} -> {:ok, DateTime.shift_zone!(datetime, "Etc/UTC")}
      _ -> {:error, :invalid_fire_time}
    end
  end

  defp normalize_fire_time(fire_time, _now) when is_integer(fire_time) do
    {:ok, DateTime.from_unix!(fire_time, :millisecond)}
  end

  defp normalize_fire_time(_, _now), do: {:error, :invalid_fire_time}

  defp normalize_schedule_type(type) when type in [:at, :cron], do: Atom.to_string(type)

  defp normalize_schedule_type(type) when is_binary(type) do
    trimmed = String.trim(type)

    if trimmed in ["at", "cron"], do: trimmed, else: "unknown"
  end

  defp normalize_schedule_type(_), do: "unknown"

  defp normalize_idempotency_key(value, _schedule_id, _fire_time_iso)
       when is_binary(value) and value != "",
       do: value

  defp normalize_idempotency_key(_value, schedule_id, fire_time_iso),
    do: schedule_id <> ":" <> fire_time_iso

  defp normalize_metadata(request) do
    metadata =
      case fetch_value(request, :metadata) do
        %{} = value -> value
        _ -> %{}
      end

    reserved = ["schedule_id", "schedule_type", "fire_time", "idempotency_key", "metadata"]

    extension =
      Enum.reduce(request, %{}, fn {key, value}, acc ->
        normalized_key = normalize_meta_key(key)

        if normalized_key in reserved do
          acc
        else
          Map.put(acc, normalized_key, value)
        end
      end)

    Map.merge(metadata, extension)
  end

  defp normalize_meta_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_meta_key(key) when is_binary(key), do: key
  defp normalize_meta_key(key), do: inspect(key)

  defp prune_recent_keys(state, now_ms) do
    threshold = now_ms - state.dedup_ttl_ms

    recent_keys =
      Enum.reduce(state.recent_keys, %{}, fn {key, seen_ms}, acc ->
        if seen_ms >= threshold, do: Map.put(acc, key, seen_ms), else: acc
      end)

    %{state | recent_keys: recent_keys}
  end

  defp normalize_positive_integer(value, _fallback)
       when is_integer(value) and value > 0,
       do: value

  defp normalize_positive_integer(_value, fallback), do: fallback

  defp fetch_value(request, key),
    do: Map.get(request, key) || Map.get(request, Atom.to_string(key))

  defp event_bus_topic(opts, config) do
    dispatch_server_config = Application.get_env(:men, Men.Gateway.DispatchServer, [])

    Keyword.get(
      opts,
      :event_bus_topic,
      Keyword.get(
        config,
        :event_bus_topic,
        Keyword.get(dispatch_server_config, :event_bus_topic, @default_topic)
      )
    )
  end

  defp now_utc(clock) do
    clock.()
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute([:men, :gateway, :task_dispatcher, event], %{count: 1}, metadata)
  rescue
    _ -> :ok
  end
end
