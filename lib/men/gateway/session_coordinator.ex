defmodule Men.Gateway.SessionCoordinator do
  @moduledoc """
  Gateway 会话协调器：维护 `session_key -> runtime_session_id` 本地映射。
  """

  use GenServer

  require Logger

  @default_ttl_ms 300_000
  @default_gc_interval_ms 60_000
  @default_max_entries 10_000
  @default_invalidation_codes [:runtime_session_not_found]

  @type mapping_entry :: Men.Gateway.Types.session_mapping_entry()
  @type invalidation_reason :: Men.Gateway.Types.session_invalidation_reason()

  @type state :: %{
          table: :ets.tid(),
          reverse_table: :ets.tid(),
          ttl_ms: pos_integer(),
          gc_interval_ms: pos_integer(),
          max_entries: pos_integer(),
          invalidation_codes: MapSet.t(String.t())
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get_or_create(binary(), (() -> binary())) :: {:ok, binary()} | {:error, term()}
  def get_or_create(session_key, create_fun)
      when is_binary(session_key) and is_function(create_fun, 0) do
    get_or_create(__MODULE__, session_key, create_fun)
  end

  @spec get_or_create(GenServer.server(), binary(), (() -> binary())) ::
          {:ok, binary()} | {:error, term()}
  def get_or_create(server, session_key, create_fun)
      when is_binary(session_key) and is_function(create_fun, 0) do
    GenServer.call(server, {:get_or_create, session_key, create_fun})
  end

  @spec get_or_create_session(binary()) :: {:ok, binary()} | {:error, term()}
  def get_or_create_session(session_key) when is_binary(session_key) do
    get_or_create_session(__MODULE__, session_key)
  end

  @spec get_or_create_session(GenServer.server(), binary()) :: {:ok, binary()} | {:error, term()}
  def get_or_create_session(server, session_key) when is_binary(session_key) do
    GenServer.call(server, {:get_or_create_session, session_key})
  end

  @spec rebuild_session(binary()) :: {:ok, binary()} | {:error, term()}
  def rebuild_session(session_key) when is_binary(session_key) do
    rebuild_session(__MODULE__, session_key)
  end

  @spec rebuild_session(GenServer.server(), binary()) :: {:ok, binary()} | {:error, term()}
  def rebuild_session(server, session_key) when is_binary(session_key) do
    GenServer.call(server, {:rebuild_session, session_key})
  end

  @spec invalidate_by_session_key(invalidation_reason()) :: :ok | :ignored | :not_found
  def invalidate_by_session_key(reason), do: invalidate_by_session_key(__MODULE__, reason)

  @spec invalidate_by_session_key(GenServer.server(), invalidation_reason()) ::
          :ok | :ignored | :not_found
  def invalidate_by_session_key(server, reason) do
    GenServer.call(server, {:invalidate_by_session_key, reason})
  end

  @spec invalidate_by_runtime_session_id(invalidation_reason()) :: :ok | :ignored | :not_found
  def invalidate_by_runtime_session_id(reason),
    do: invalidate_by_runtime_session_id(__MODULE__, reason)

  @spec invalidate_by_runtime_session_id(GenServer.server(), invalidation_reason()) ::
          :ok | :ignored | :not_found
  def invalidate_by_runtime_session_id(server, reason) do
    GenServer.call(server, {:invalidate_by_runtime_session_id, reason})
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:men, __MODULE__, [])
    ttl_ms = positive_integer(opts, config, :ttl_ms, @default_ttl_ms)
    gc_interval_ms = positive_integer(opts, config, :gc_interval_ms, @default_gc_interval_ms)
    max_entries = positive_integer(opts, config, :max_entries, @default_max_entries)

    invalidation_codes =
      opts
      |> Keyword.get(:invalidation_codes, Keyword.get(config, :invalidation_codes, @default_invalidation_codes))
      |> normalize_invalidation_codes()

    state = %{
      table: :ets.new(__MODULE__, [:set, :private]),
      reverse_table: :ets.new(__MODULE__, [:set, :private]),
      ttl_ms: ttl_ms,
      gc_interval_ms: gc_interval_ms,
      max_entries: max_entries,
      invalidation_codes: invalidation_codes
    }

    schedule_gc(gc_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:get_or_create, session_key, create_fun}, _from, state) do
    resolve_or_create_runtime_session(state, session_key, create_fun)
  end

  @impl true
  def handle_call({:get_or_create_session, session_key}, _from, state) do
    resolve_or_create_runtime_session(state, session_key, &generate_runtime_session_id/0)
  end

  @impl true
  def handle_call({:rebuild_session, session_key}, _from, state) do
    now_ms = now_ms()

    case lookup_entry(state, session_key) do
      {:ok, entry} ->
        delete_entry(state, entry)

      :not_found ->
        :ok
    end

    create_and_store(state, session_key, &generate_runtime_session_id/0, now_ms)
  end

  @impl true
  def handle_call({:invalidate_by_session_key, reason}, _from, state) do
    reply =
      with {:ok, session_key, code, runtime_session_id} <- normalize_reason_by_session_key(state, reason),
           :ok <- ensure_invalidation_code(state, code) do
        case lookup_entry(state, session_key) do
          {:ok, entry} ->
            if runtime_session_id in [nil, entry.runtime_session_id] do
              delete_entry(state, entry)
              Logger.info("gateway session invalidated by session_key=#{session_key} code=#{code}")
              :ok
            else
              :not_found
            end

          :not_found ->
            :not_found
        end
      else
        {:error, :not_whitelisted} -> :ignored
        _ -> :ignored
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:invalidate_by_runtime_session_id, reason}, _from, state) do
    reply =
      with {:ok, runtime_session_id, code, session_key} <- normalize_reason_by_runtime_id(state, reason),
           :ok <- ensure_invalidation_code(state, code) do
        case lookup_session_key_by_runtime_id(state, runtime_session_id) do
          {:ok, actual_session_key} ->
            if session_key in [nil, actual_session_key] do
              case lookup_entry(state, actual_session_key) do
                {:ok, entry} ->
                  delete_entry(state, entry)
                  Logger.info("gateway session invalidated by runtime_session_id=#{runtime_session_id} code=#{code}")
                  :ok

                :not_found ->
                  :not_found
              end
            else
              :not_found
            end

          :not_found ->
            :not_found
        end
      else
        {:error, :not_whitelisted} -> :ignored
        _ -> :ignored
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:gc, state) do
    now_ms = now_ms()
    expired_entries = collect_expired_entries(state, now_ms)

    Enum.each(expired_entries, &delete_entry(state, &1))

    if expired_entries != [] do
      Logger.debug("gateway session gc removed=#{length(expired_entries)}")
    end

    schedule_gc(state.gc_interval_ms)
    {:noreply, state}
  end

  defp create_and_store(state, session_key, create_fun, now_ms) do
    case create_fun.() do
      runtime_session_id when is_binary(runtime_session_id) and runtime_session_id != "" ->
        evict_if_needed(state)

        entry = %{
          session_key: session_key,
          runtime_session_id: runtime_session_id,
          last_access_at: now_ms,
          expires_at: now_ms + state.ttl_ms
        }

        store_entry(state, entry)
        {:reply, {:ok, runtime_session_id}, state}

      invalid ->
        {:reply, {:error, {:invalid_runtime_session_id, invalid}}, state}
    end
  end

  defp resolve_or_create_runtime_session(state, session_key, create_fun) do
    now_ms = now_ms()

    case lookup_entry(state, session_key) do
      {:ok, entry} ->
        if expired?(entry, now_ms) do
          delete_entry(state, entry)
          create_and_store(state, session_key, create_fun, now_ms)
        else
          refreshed = refresh_entry(state, entry, now_ms)
          {:reply, {:ok, refreshed.runtime_session_id}, state}
        end

      :not_found ->
        create_and_store(state, session_key, create_fun, now_ms)
    end
  end

  defp refresh_entry(state, entry, now_ms) do
    refreshed = %{entry | last_access_at: now_ms, expires_at: now_ms + state.ttl_ms}
    store_entry(state, refreshed)
    refreshed
  end

  defp lookup_entry(state, session_key) do
    case :ets.lookup(state.table, session_key) do
      [{^session_key, runtime_session_id, last_access_at, expires_at}] ->
        {:ok,
         %{
           session_key: session_key,
           runtime_session_id: runtime_session_id,
           last_access_at: last_access_at,
           expires_at: expires_at
         }}

      [] ->
        :not_found
    end
  end

  defp lookup_session_key_by_runtime_id(state, runtime_session_id) do
    case :ets.lookup(state.reverse_table, runtime_session_id) do
      [{^runtime_session_id, session_key}] -> {:ok, session_key}
      [] -> :not_found
    end
  end

  defp store_entry(state, entry) do
    :ets.insert(
      state.table,
      {entry.session_key, entry.runtime_session_id, entry.last_access_at, entry.expires_at}
    )

    :ets.insert(state.reverse_table, {entry.runtime_session_id, entry.session_key})
    :ok
  end

  defp delete_entry(state, entry) do
    :ets.delete(state.table, entry.session_key)
    :ets.delete(state.reverse_table, entry.runtime_session_id)
    :ok
  end

  defp expired?(entry, now_ms), do: entry.expires_at <= now_ms

  defp collect_expired_entries(state, now_ms) do
    :ets.foldl(
      fn {session_key, runtime_session_id, last_access_at, expires_at}, acc ->
        if expires_at <= now_ms do
          [
            %{
              session_key: session_key,
              runtime_session_id: runtime_session_id,
              last_access_at: last_access_at,
              expires_at: expires_at
            }
            | acc
          ]
        else
          acc
        end
      end,
      [],
      state.table
    )
  end

  defp evict_if_needed(state) do
    size = :ets.info(state.table, :size)

    if size >= state.max_entries do
      case oldest_entry(state) do
        {:ok, entry} ->
          delete_entry(state, entry)
          Logger.debug("gateway session lru evicted session_key=#{entry.session_key}")

        :not_found ->
          :ok
      end
    end
  end

  defp oldest_entry(state) do
    :ets.foldl(
      fn {session_key, runtime_session_id, last_access_at, expires_at}, acc ->
        current = %{
          session_key: session_key,
          runtime_session_id: runtime_session_id,
          last_access_at: last_access_at,
          expires_at: expires_at
        }

        case acc do
          nil ->
            current

          existing when existing.last_access_at <= current.last_access_at ->
            existing

          _ ->
            current
        end
      end,
      nil,
      state.table
    )
    |> case do
      nil -> :not_found
      entry -> {:ok, entry}
    end
  end

  defp normalize_reason_by_session_key(
         _state,
         %{session_key: session_key, runtime_session_id: runtime_session_id, code: code}
       )
       when is_binary(session_key) and is_binary(runtime_session_id),
       do: {:ok, session_key, normalize_code(code), runtime_session_id}

  defp normalize_reason_by_session_key(_state, %{session_key: session_key, code: code})
       when is_binary(session_key),
       do: {:ok, session_key, normalize_code(code), nil}

  defp normalize_reason_by_session_key(_state, {session_key, code}) when is_binary(session_key),
    do: {:ok, session_key, normalize_code(code), nil}

  defp normalize_reason_by_session_key(_state, _reason), do: {:error, :invalid_reason}

  defp normalize_reason_by_runtime_id(
         _state,
         %{runtime_session_id: runtime_session_id, session_key: session_key, code: code}
       )
       when is_binary(runtime_session_id) and is_binary(session_key),
       do: {:ok, runtime_session_id, normalize_code(code), session_key}

  defp normalize_reason_by_runtime_id(_state, %{runtime_session_id: runtime_session_id, code: code})
       when is_binary(runtime_session_id),
       do: {:ok, runtime_session_id, normalize_code(code), nil}

  defp normalize_reason_by_runtime_id(_state, {runtime_session_id, code})
       when is_binary(runtime_session_id),
       do: {:ok, runtime_session_id, normalize_code(code), nil}

  defp normalize_reason_by_runtime_id(_state, _reason), do: {:error, :invalid_reason}

  defp ensure_invalidation_code(state, code) do
    if MapSet.member?(state.invalidation_codes, code), do: :ok, else: {:error, :not_whitelisted}
  end

  defp normalize_invalidation_codes(codes) when is_list(codes) do
    codes
    |> Enum.map(&normalize_code/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_invalidation_codes(_), do: normalize_invalidation_codes(@default_invalidation_codes)

  defp normalize_code(code) when is_atom(code), do: code |> Atom.to_string() |> String.downcase()
  defp normalize_code(code) when is_binary(code), do: code |> String.trim() |> String.downcase()
  defp normalize_code(_), do: ""

  defp positive_integer(opts, config, key, default) do
    value = Keyword.get(opts, key, Keyword.get(config, key, default))
    if is_integer(value) and value > 0, do: value, else: default
  end

  # 统一由协调器生成 runtime session id，保证重建语义原子化。
  defp generate_runtime_session_id do
    "runtime-session-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp schedule_gc(interval_ms), do: Process.send_after(self(), :gc, interval_ms)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
