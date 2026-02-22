defmodule Men.Gateway.InboxStore do
  @moduledoc """
  Inbox ETS 存储：提供 event_id 去重与按 ets_keys 的版本守卫。
  """

  alias Men.Gateway.EventEnvelope

  @default_event_table :"#{__MODULE__}.event_dedup"
  @default_scope_table :"#{__MODULE__}.scope_versions"

  @type put_result ::
          {:ok, EventEnvelope.t()}
          | {:duplicate, EventEnvelope.t()}
          | {:stale, EventEnvelope.t()}
          | {:error, term()}

  @spec put(EventEnvelope.t(), keyword() | map()) :: put_result()
  def put(envelope, opts \\ [])

  def put(%EventEnvelope{} = envelope, opts) do
    options = normalize_opts(opts)
    event_table = ensure_table(Map.get(options, :event_table, @default_event_table))
    scope_table = ensure_table(Map.get(options, :scope_table, @default_scope_table))

    with :ok <- validate_envelope(envelope) do
      case :ets.insert_new(event_table, {envelope.event_id, envelope.ts}) do
        true ->
          case upsert_latest(scope_table, scope_key(envelope.ets_keys), envelope) do
            :ok -> {:ok, envelope}
            :stale -> {:stale, envelope}
          end

        false ->
          {:duplicate, envelope}
      end
    end
  end

  def put(_invalid, _opts), do: {:error, :invalid_event_envelope}

  @spec latest_by_ets_keys([String.t()], keyword() | map()) ::
          {:ok, EventEnvelope.t()} | :not_found
  def latest_by_ets_keys(ets_keys, opts \\ []) when is_list(ets_keys) do
    options = normalize_opts(opts)
    scope_table = ensure_table(Map.get(options, :scope_table, @default_scope_table))
    key = scope_key(ets_keys)

    case :ets.lookup(scope_table, key) do
      [{^key, _version, envelope}] -> {:ok, envelope}
      _ -> :not_found
    end
  end

  @spec reset(keyword() | map()) :: :ok
  def reset(opts \\ []) do
    options = normalize_opts(opts)
    event_table = ensure_table(Map.get(options, :event_table, @default_event_table))
    scope_table = ensure_table(Map.get(options, :scope_table, @default_scope_table))
    :ets.delete_all_objects(event_table)
    :ets.delete_all_objects(scope_table)
    :ok
  end

  # 同一个 scope_key 的版本推进采用全局锁，避免并发覆盖高版本。
  defp upsert_latest(scope_table, key, envelope) do
    :global.trans({__MODULE__, key}, fn ->
      case :ets.lookup(scope_table, key) do
        [] ->
          :ets.insert(scope_table, {key, envelope.version, envelope})
          :ok

        [{^key, current_version, _current_envelope}] when envelope.version > current_version ->
          :ets.insert(scope_table, {key, envelope.version, envelope})
          :ok

        [{^key, current_version, _current_envelope}] when envelope.version <= current_version ->
          :stale
      end
    end)
  end

  defp scope_key(ets_keys) when is_list(ets_keys) do
    ets_keys
    |> Enum.map(&to_string/1)
    |> Enum.join("|")
  end

  defp validate_envelope(%EventEnvelope{event_id: event_id, ets_keys: ets_keys, version: version})
       when is_binary(event_id) and event_id != "" and is_list(ets_keys) and is_integer(version) and
              version >= 0,
       do: :ok

  defp validate_envelope(_), do: {:error, :invalid_event_envelope}

  defp ensure_table(table_name) when is_atom(table_name) do
    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

        table_name

      tid when is_reference(tid) ->
        table_name
    end
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(_), do: %{}
end
