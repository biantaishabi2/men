defmodule Men.Gateway.EventBus do
  @moduledoc """
  网关事件总线薄封装，仅承载轻量事件信号。
  """

  @default_topic "gateway_events"
  @schedule_event_type "task_schedule_triggered"
  @schedule_required_fields [
    :schedule_id,
    :fire_time,
    :idempotency_key,
    :schedule_type,
    :triggered_at
  ]

  @spec publish(String.t(), map()) :: :ok
  def publish(topic \\ @default_topic, payload) when is_binary(topic) and is_map(payload) do
    Phoenix.PubSub.broadcast(Men.PubSub, topic, {:gateway_event, payload})
  rescue
    _ -> :ok
  end

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic \\ @default_topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(Men.PubSub, topic)
  end

  @spec publish_schedule_trigger(String.t(), map()) :: :ok
  def publish_schedule_trigger(topic \\ @default_topic, attrs)
      when is_binary(topic) and is_map(attrs) do
    payload = %{
      type: @schedule_event_type,
      schedule_id: fetch_text(attrs, :schedule_id, "unknown_schedule"),
      fire_time: fetch_utc_iso8601(attrs, :fire_time),
      idempotency_key: fetch_text(attrs, :idempotency_key, "missing_idempotency_key"),
      schedule_type: fetch_text(attrs, :schedule_type, "unknown"),
      triggered_at: fetch_utc_iso8601(attrs, :triggered_at),
      metadata: build_schedule_metadata(attrs)
    }

    publish(topic, payload)
  end

  defp build_schedule_metadata(attrs) do
    base_metadata =
      case fetch_value(attrs, :metadata) do
        %{} = metadata -> metadata
        _ -> %{}
      end

    extra_metadata =
      Enum.reduce(attrs, %{}, fn {key, value}, acc ->
        normalized_key = normalize_meta_key(key)

        if normalized_key in schedule_reserved_keys() do
          acc
        else
          Map.put(acc, normalized_key, value)
        end
      end)

    Map.merge(base_metadata, extra_metadata)
  end

  defp schedule_reserved_keys do
    Enum.map(@schedule_required_fields, &Atom.to_string/1) ++ ["metadata"]
  end

  defp fetch_text(attrs, key, fallback) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> fallback
    end
  end

  defp fetch_utc_iso8601(attrs, key) do
    value = fetch_value(attrs, key)
    now = DateTime.utc_now()

    cond do
      is_struct(value, DateTime) ->
        value
        |> DateTime.shift_zone!("Etc/UTC")
        |> DateTime.to_iso8601()

      is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} ->
            datetime
            |> DateTime.shift_zone!("Etc/UTC")
            |> DateTime.to_iso8601()

          _ ->
            DateTime.to_iso8601(now)
        end

      is_integer(value) ->
        value
        |> DateTime.from_unix!(:millisecond)
        |> DateTime.to_iso8601()

      true ->
        DateTime.to_iso8601(now)
    end
  end

  defp fetch_value(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp normalize_meta_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_meta_key(key) when is_binary(key), do: key
  defp normalize_meta_key(key), do: inspect(key)
end
