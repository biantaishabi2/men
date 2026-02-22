defmodule Men.Gateway.EventEnvelope do
  @moduledoc """
  统一事件信封：将外部输入归一化为可判定、可追踪的内部结构。
  """

  @enforce_keys [
    :type,
    :source,
    :target,
    :event_id,
    :version,
    :ets_keys,
    :wake,
    :inbox_only,
    :payload,
    :ts,
    :meta
  ]
  defstruct [
    :type,
    :source,
    :target,
    :event_id,
    :version,
    :wake,
    :inbox_only,
    :force_wake,
    :ets_keys,
    :payload,
    :ts,
    :meta
  ]

  @type t :: %__MODULE__{
          type: String.t(),
          source: String.t(),
          target: String.t(),
          event_id: String.t(),
          version: non_neg_integer(),
          wake: boolean() | nil,
          inbox_only: boolean() | nil,
          force_wake: boolean(),
          ets_keys: [String.t()],
          payload: term(),
          ts: integer(),
          meta: map()
        }

  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{} = attrs) do
    with {:ok, normalized} <- stringify_keys(attrs),
         {:ok, type} <- fetch_required_text(normalized, "type"),
         {:ok, source} <- fetch_text(normalized, "source", "unknown"),
         {:ok, target} <- fetch_text(normalized, "target", "unknown"),
         {:ok, event_id} <- fetch_required_text(normalized, "event_id"),
         {:ok, version} <- fetch_version(normalized["version"]),
         {:ok, wake} <- fetch_optional_boolean(normalized["wake"], :wake),
         {:ok, inbox_only} <- fetch_optional_boolean(normalized["inbox_only"], :inbox_only),
         {:ok, force_wake} <- fetch_boolean(normalized["force_wake"], false, :force_wake),
         {:ok, ets_keys} <- fetch_ets_keys(normalized["ets_keys"], type, source, target),
         {:ok, ts} <- fetch_timestamp(normalized["ts"]),
         {:ok, meta} <- fetch_meta(normalized["meta"]) do
      payload = Map.get(normalized, "payload", %{})

      {:ok,
       %__MODULE__{
         type: type,
         source: source,
         target: target,
         event_id: event_id,
         version: version,
         wake: wake,
         inbox_only: inbox_only,
         force_wake: force_wake,
         ets_keys: ets_keys,
         payload: payload,
         ts: ts,
         meta: meta
       }}
    end
  end

  def from_map(_), do: {:error, :invalid_event_envelope}

  @spec normalize(map() | t()) :: {:ok, t()} | {:error, term()}
  def normalize(%__MODULE__{} = envelope) do
    envelope
    |> Map.from_struct()
    |> from_map()
  end

  def normalize(%{} = attrs), do: from_map(attrs)
  def normalize(_), do: {:error, :invalid_event_envelope}

  defp stringify_keys(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_key(key) do
        {:ok, normalized_key} ->
          {:cont, {:ok, Map.put(acc, normalized_key, value)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_integer(key), do: {:ok, Integer.to_string(key)}
  defp normalize_key(key) when is_float(key), do: {:ok, :erlang.float_to_binary(key)}
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
        atom_text = value |> Atom.to_string() |> String.trim()

        if atom_text == "",
          do: {:error, {:invalid_field, String.to_atom(key)}},
          else: {:ok, atom_text}

      _ ->
        {:error, {:invalid_field, String.to_atom(key)}}
    end
  end

  defp fetch_text(map, key, default) do
    case Map.get(map, key, default) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: {:ok, default}, else: {:ok, trimmed}

      value when is_atom(value) ->
        atom_text = value |> Atom.to_string() |> String.trim()

        if atom_text == "", do: {:ok, default}, else: {:ok, atom_text}

      nil ->
        {:ok, default}

      _ ->
        {:error, {:invalid_field, String.to_atom(key)}}
    end
  end

  defp fetch_version(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp fetch_version(nil), do: {:ok, 0}
  defp fetch_version(_), do: {:error, {:invalid_field, :version}}

  defp fetch_optional_boolean(nil, _field), do: {:ok, nil}
  defp fetch_optional_boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp fetch_optional_boolean(_, field), do: {:error, {:invalid_field, field}}

  defp fetch_boolean(nil, default, _field), do: {:ok, default}
  defp fetch_boolean(value, _default, _field) when is_boolean(value), do: {:ok, value}
  defp fetch_boolean(_, _default, field), do: {:error, {:invalid_field, field}}

  # ets_keys 为空时回落到 type/source/target，确保后续版本守卫有稳定作用域。
  defp fetch_ets_keys(nil, type, source, target), do: {:ok, [type, source, target]}

  defp fetch_ets_keys(value, _type, _source, _target) when is_list(value) do
    keys =
      value
      |> Enum.map(&normalize_ets_key/1)
      |> Enum.reject(&is_nil/1)

    if keys == [], do: {:error, {:invalid_field, :ets_keys}}, else: {:ok, keys}
  end

  defp fetch_ets_keys(_, _, _, _), do: {:error, {:invalid_field, :ets_keys}}

  defp normalize_ets_key(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_ets_key(value) when is_atom(value), do: normalize_ets_key(Atom.to_string(value))
  defp normalize_ets_key(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_ets_key(_), do: nil

  defp fetch_timestamp(value) when is_integer(value), do: {:ok, value}
  defp fetch_timestamp(nil), do: {:ok, System.system_time(:millisecond)}
  defp fetch_timestamp(_), do: {:error, {:invalid_field, :ts}}

  defp fetch_meta(nil), do: {:ok, %{}}
  defp fetch_meta(%{} = meta), do: {:ok, meta}
  defp fetch_meta(_), do: {:error, {:invalid_field, :meta}}
end
