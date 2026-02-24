defmodule Men.Ops.Policy.Cache do
  @moduledoc """
  Ops Policy ETS 缓存层。
  """

  use GenServer

  @table :men_ops_policy_cache
  @meta_table :men_ops_policy_cache_meta
  @default_ttl_ms 60_000

  @type identity :: %{
          tenant: String.t(),
          env: String.t(),
          scope: String.t(),
          policy_key: String.t()
        }

  @type cache_entry :: %{
          value: map(),
          policy_version: non_neg_integer(),
          updated_by: String.t(),
          updated_at: DateTime.t(),
          cached_at_ms: integer(),
          expire_at_ms: integer()
        }

  @type lookup_result ::
          {:hit, cache_entry()}
          | {:expired, cache_entry()}
          | :miss

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    ensure_tables()
    {:ok, %{}}
  end

  @spec get(identity()) :: lookup_result()
  def get(identity) do
    with {:ok, key} <- normalize_identity(identity),
         true <- ensure_tables() do
      now = now_ms()

      case :ets.lookup(@table, key) do
        [{^key, entry}] ->
          if entry.expire_at_ms >= now do
            {:hit, entry}
          else
            {:expired, entry}
          end

        _ ->
          :miss
      end
    else
      _ -> :miss
    end
  end

  @spec put(identity(), map(), keyword()) :: :ok | {:error, term()}
  def put(identity, policy_record, opts \\ []) when is_map(policy_record) do
    ttl_ms = Keyword.get(opts, :ttl_ms, ttl_ms())

    with {:ok, key} <- normalize_identity(identity),
         {:ok, entry} <- normalize_entry(policy_record, ttl_ms),
         true <- ensure_tables() do
      :ets.insert(@table, {key, entry})
      bump_latest_version(entry.policy_version)
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :cache_unavailable}
    end
  end

  @spec put_many([map()], keyword()) :: :ok
  def put_many(records, opts \\ []) when is_list(records) do
    Enum.each(records, fn record ->
      identity = %{
        tenant: record.tenant,
        env: record.env,
        scope: record.scope,
        policy_key: record.policy_key
      }

      _ = put(identity, record, opts)
    end)

    :ok
  end

  @spec latest_version() :: non_neg_integer()
  def latest_version do
    ensure_tables()

    case :ets.lookup(@meta_table, :latest_version) do
      [{:latest_version, version}] when is_integer(version) and version >= 0 -> version
      _ -> 0
    end
  end

  @spec reset() :: :ok
  def reset do
    ensure_tables()
    :ets.delete_all_objects(@table)
    :ets.insert(@meta_table, {:latest_version, 0})
    :ok
  end

  @spec table_name() :: atom()
  def table_name, do: @table

  @spec ttl_ms() :: pos_integer()
  def ttl_ms do
    Application.get_env(:men, :ops_policy, [])
    |> Keyword.get(:cache_ttl_ms, @default_ttl_ms)
    |> normalize_positive_integer(@default_ttl_ms)
  end

  defp ensure_tables do
    ensure_table(@table)
    ensure_table(@meta_table)

    if :ets.lookup(@meta_table, :latest_version) == [] do
      :ets.insert(@meta_table, {:latest_version, 0})
    end

    true
  rescue
    _ -> false
  end

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [
          :set,
          :named_table,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end
  end

  defp normalize_identity(%{tenant: tenant, env: env, scope: scope, policy_key: key})
       when is_binary(tenant) and tenant != "" and is_binary(env) and env != "" and
              is_binary(scope) and scope != "" and is_binary(key) and key != "" do
    {:ok, {tenant, env, scope, key}}
  end

  defp normalize_identity(identity) when is_list(identity),
    do: normalize_identity(Map.new(identity))

  defp normalize_identity(_), do: {:error, :invalid_identity}

  defp normalize_entry(record, ttl_ms)
       when is_map(record) and is_integer(record.policy_version) and record.policy_version >= 0 do
    now = now_ms()

    {:ok,
     %{
       value: Map.get(record, :value, %{}),
       policy_version: record.policy_version,
       updated_by: Map.get(record, :updated_by, "unknown"),
       updated_at: Map.get(record, :updated_at, DateTime.utc_now()),
       cached_at_ms: now,
       expire_at_ms: now + normalize_positive_integer(ttl_ms, @default_ttl_ms)
     }}
  end

  defp normalize_entry(_, _), do: {:error, :invalid_record}

  defp bump_latest_version(version) when is_integer(version) and version >= 0 do
    true = ensure_tables()

    replaced =
      :ets.select_replace(@meta_table, [
        {{:latest_version, :"$1"}, [{:<, :"$1", version}], [{{:latest_version, version}}]}
      ])

    if replaced == 0 do
      :ets.insert_new(@meta_table, {:latest_version, version})
      :ok
    else
      :ok
    end
  end

  defp normalize_positive_integer(value, _default)
       when is_integer(value) and value > 0,
       do: value

  defp normalize_positive_integer(_, default), do: default

  defp now_ms, do: System.system_time(:millisecond)
end
