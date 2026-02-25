defmodule Men.Gateway.EventEnvelope do
  @moduledoc """
  统一事件信封：校验必填字段并规范化轻量事件载荷。
  """

  alias Men.Gateway.Types

  @task_state_event_type "task_state_changed"
  @task_state_mapping %{
    "pending" => :pending,
    "ready" => :ready,
    "running" => :running,
    "succeeded" => :succeeded,
    "failed" => :failed,
    "cancelled" => :cancelled
  }

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

  @doc """
  任务状态事件契约归一化。

  MUST 字段：
  - `task_id`
  - `from_state`
  - `to_state`
  - `occurred_at`（UTC ISO8601）

  SHOULD 字段：
  - `attempt`
  - `reason_code`
  - `reason_message`
  - `idempotent_hit`
  """
  @spec normalize_task_state_event(map() | t()) :: {:ok, t()} | {:error, term()}
  def normalize_task_state_event(attrs) do
    with {:ok, envelope} <- normalize(attrs),
         :ok <- validate_task_event_type(envelope.type),
         {:ok, payload} <- normalize_task_payload(envelope.payload),
         {:ok, meta} <- normalize_task_event_meta(envelope.meta),
         ets_keys <- normalize_task_event_ets_keys(envelope.ets_keys, payload) do
      {:ok, %{envelope | payload: payload, meta: meta, ets_keys: ets_keys}}
    end
  end

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

  defp validate_task_event_type(@task_state_event_type), do: :ok
  defp validate_task_event_type(_), do: {:error, {:invalid_field, :type}}

  defp normalize_task_payload(payload) when is_map(payload) do
    with {:ok, normalized} <- stringify_keys(payload),
         {:ok, task_id} <- fetch_required_text(normalized, "task_id"),
         {:ok, from_state} <- fetch_task_state(normalized["from_state"], :from_state),
         {:ok, to_state} <- fetch_task_state(normalized["to_state"], :to_state),
         :ok <- validate_task_transition(from_state, to_state),
         {:ok, occurred_at} <- fetch_occurred_at(normalized["occurred_at"]),
         {:ok, attempt} <- fetch_optional_positive_integer(normalized["attempt"], :attempt),
         {:ok, reason_code} <- fetch_optional_text(normalized["reason_code"]),
         {:ok, reason_message} <- fetch_optional_text(normalized["reason_message"]),
         {:ok, idempotent_hit} <-
           fetch_optional_boolean(normalized["idempotent_hit"], :idempotent_hit) do
      payload =
        %{
          task_id: task_id,
          from_state: from_state,
          to_state: to_state,
          occurred_at: occurred_at
        }
        |> maybe_put(:attempt, attempt)
        |> maybe_put(:reason_code, reason_code)
        |> maybe_put(:reason_message, reason_message)
        |> maybe_put(:idempotent_hit, idempotent_hit)

      {:ok, payload}
    end
  end

  defp normalize_task_payload(_), do: {:error, {:invalid_field, :payload}}

  defp fetch_task_state(value, field) when is_atom(value) do
    if value in Types.task_states(), do: {:ok, value}, else: {:error, {:invalid_field, field}}
  end

  defp fetch_task_state(value, field) when is_binary(value) do
    value
    |> String.trim()
    |> then(&Map.get(@task_state_mapping, &1))
    |> case do
      nil -> {:error, {:invalid_field, field}}
      state -> {:ok, state}
    end
  end

  defp fetch_task_state(_, field), do: {:error, {:invalid_field, field}}

  defp validate_task_transition(from_state, to_state) do
    case Types.validate_task_transition(from_state, to_state) do
      :ok ->
        :ok

      {:error, %{code: code}} ->
        {:error, %{code: code, from_state: from_state, to_state: to_state}}
    end
  end

  defp fetch_occurred_at(value) when is_binary(value) do
    trimmed = String.trim(value)

    with {:ok, dt, 0} <- DateTime.from_iso8601(trimmed) do
      {:ok, DateTime.to_iso8601(dt)}
    else
      _ -> {:error, {:invalid_field, :occurred_at}}
    end
  end

  defp fetch_occurred_at(_), do: {:error, {:invalid_field, :occurred_at}}

  defp fetch_optional_positive_integer(nil, _field), do: {:ok, nil}

  defp fetch_optional_positive_integer(value, _field) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp fetch_optional_positive_integer(_, field), do: {:error, {:invalid_field, field}}

  defp normalize_task_event_meta(meta) when is_map(meta) do
    {:ok,
     meta
     |> Map.put_new(:audit, true)
     |> Map.put_new(:replayable, true)}
  end

  defp normalize_task_event_meta(_), do: {:error, {:invalid_field, :meta}}

  defp normalize_task_event_ets_keys(ets_keys, payload) do
    [
      payload.task_id,
      Atom.to_string(payload.from_state),
      Atom.to_string(payload.to_state) | ets_keys
    ]
    |> Enum.uniq()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
