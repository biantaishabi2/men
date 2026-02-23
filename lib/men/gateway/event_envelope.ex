defmodule Men.Gateway.EventEnvelope do
  @moduledoc """
  统一事件信封：校验必填字段并规范化轻量事件载荷。
  """

  @enforce_keys [
    :type,
    :source,
    :session_key,
    :event_id,
    :version,
    :ets_keys,
    :payload,
    :ts,
    :meta
  ]
  defstruct [
    :type,
    :source,
    :target,
    :session_key,
    :event_id,
    :version,
    :wake,
    :inbox_only,
    :ets_keys,
    :payload,
    :ts,
    :meta
  ]

  @type t :: %__MODULE__{
          type: String.t(),
          source: String.t(),
          target: String.t() | nil,
          session_key: String.t(),
          event_id: String.t(),
          version: non_neg_integer(),
          wake: boolean() | nil,
          inbox_only: boolean() | nil,
          ets_keys: [String.t()],
          payload: map(),
          ts: integer(),
          meta: map()
        }

  @spec normalize(map() | t()) :: {:ok, t()} | {:error, term()}
  def normalize(%__MODULE__{} = envelope) do
    envelope
    |> Map.from_struct()
    |> normalize()
  end

  def normalize(%{} = attrs) do
    with {:ok, normalized} <- stringify_keys(attrs),
         {:ok, type} <- fetch_required_text(normalized, "type"),
         {:ok, source} <- fetch_required_text(normalized, "source"),
         {:ok, session_key} <- fetch_required_text(normalized, "session_key"),
         {:ok, event_id} <- fetch_required_text(normalized, "event_id"),
         {:ok, version} <- fetch_version(Map.get(normalized, "version")),
         {:ok, ets_keys} <-
           fetch_ets_keys(Map.get(normalized, "ets_keys"), type, source, session_key, event_id),
         {:ok, payload} <- fetch_payload(Map.get(normalized, "payload", %{})),
         {:ok, wake} <- fetch_optional_boolean(Map.get(normalized, "wake"), :wake),
         {:ok, inbox_only} <-
           fetch_optional_boolean(Map.get(normalized, "inbox_only"), :inbox_only),
         {:ok, target} <- fetch_optional_text(Map.get(normalized, "target")),
         {:ok, ts} <- fetch_timestamp(Map.get(normalized, "ts")),
         {:ok, meta} <- fetch_meta(Map.get(normalized, "meta")) do
      {:ok,
       %__MODULE__{
         type: type,
         source: source,
         target: target,
         session_key: session_key,
         event_id: event_id,
         version: version,
         wake: wake,
         inbox_only: inbox_only,
         ets_keys: ets_keys,
         payload: payload,
         ts: ts,
         meta: meta
       }}
    end
  end

  def normalize(_), do: {:error, :invalid_event_envelope}

  defp stringify_keys(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_key(key) do
        {:ok, k} -> {:cont, {:ok, Map.put(acc, k, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(_), do: {:error, {:invalid_field, :key}}

  defp fetch_required_text(map, key) do
    case Map.get(map, key) do
      nil ->
        {:error, {:invalid_field, String.to_atom(key)}}

      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "",
          do: {:error, {:invalid_field, String.to_atom(key)}},
          else: {:ok, trimmed}

      value when is_atom(value) ->
        fetch_required_text(%{key => Atom.to_string(value)}, key)

      _ ->
        {:error, {:invalid_field, String.to_atom(key)}}
    end
  end

  defp fetch_optional_text(nil), do: {:ok, nil}

  defp fetch_optional_text(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: {:ok, nil}, else: {:ok, trimmed}
  end

  defp fetch_optional_text(_), do: {:error, {:invalid_field, :target}}

  defp fetch_version(nil), do: {:ok, 0}
  defp fetch_version(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp fetch_version(_), do: {:error, {:invalid_field, :version}}

  defp fetch_ets_keys(nil, type, source, session_key, event_id),
    do: {:ok, [type, source, session_key, event_id]}

  defp fetch_ets_keys(keys, _type, _source, _session_key, _event_id) when is_list(keys) do
    normalized =
      keys
      |> Enum.map(&normalize_ets_key/1)
      |> Enum.reject(&is_nil/1)

    if normalized == [], do: {:error, {:invalid_field, :ets_keys}}, else: {:ok, normalized}
  end

  defp fetch_ets_keys(_, _, _, _, _), do: {:error, {:invalid_field, :ets_keys}}

  defp normalize_ets_key(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_ets_key(value) when is_atom(value), do: normalize_ets_key(Atom.to_string(value))
  defp normalize_ets_key(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_ets_key(_), do: nil

  defp fetch_payload(payload) when is_map(payload), do: {:ok, payload}
  defp fetch_payload(_), do: {:error, {:invalid_field, :payload}}

  defp fetch_optional_boolean(nil, _field), do: {:ok, nil}
  defp fetch_optional_boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp fetch_optional_boolean(_, field), do: {:error, {:invalid_field, field}}

  defp fetch_timestamp(nil), do: {:ok, System.system_time(:millisecond)}
  defp fetch_timestamp(value) when is_integer(value), do: {:ok, value}
  defp fetch_timestamp(_), do: {:error, {:invalid_field, :ts}}

  defp fetch_meta(nil), do: {:ok, %{}}
  defp fetch_meta(value) when is_map(value), do: {:ok, value}
  defp fetch_meta(_), do: {:error, {:invalid_field, :meta}}
end
