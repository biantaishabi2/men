defmodule Men.Ops.Policy.Sync do
  @moduledoc """
  Ops Policy 的事件刷新与定时对账自愈。
  """

  use GenServer

  require Logger

  alias Men.Ops.Policy.Cache
  alias Men.Ops.Policy.Events

  @default_interval_ms 30_000
  @default_jitter_ms 5_000
  @default_failure_threshold 3

  defstruct failure_count: 0, enabled?: true

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    enabled? = Keyword.get(opts, :enabled, sync_enabled?())

    if enabled? do
      _ = Events.subscribe()
      schedule_reconcile()
    end

    {:ok, %__MODULE__{enabled?: enabled?}}
  end

  @impl true
  def handle_info({:policy_changed, _version}, %__MODULE__{enabled?: false} = state) do
    {:noreply, state}
  end

  def handle_info({:policy_changed, version}, state) do
    case refresh_since(max(version - 1, 0)) do
      {:ok, _} -> {:noreply, %{state | failure_count: 0}}
      {:error, reason} -> {:noreply, increase_failure(state, :event_refresh_failed, reason)}
    end
  end

  @impl true
  def handle_info(:reconcile, %__MODULE__{enabled?: false} = state) do
    {:noreply, state}
  end

  def handle_info(:reconcile, state) do
    next_state =
      case reconcile_once() do
        :ok -> %{state | failure_count: 0}
        {:error, reason} -> increase_failure(state, :reconcile_failed, reason)
      end

    schedule_reconcile()
    {:noreply, next_state}
  end

  @spec reconcile_now() :: :ok | {:error, term()}
  def reconcile_now do
    reconcile_once()
  end

  @spec refresh_since(non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def refresh_since(version) when is_integer(version) and version >= 0 do
    with {:ok, records} <- db_source().list_since_version(version) do
      :ok = Cache.put_many(records)

      latest =
        Enum.reduce(records, Cache.latest_version(), fn item, acc ->
          max(acc, item.policy_version)
        end)

      emit_sync_telemetry(:event_refresh, latest, records, :ok, nil)
      {:ok, length(records)}
    else
      {:error, reason} ->
        emit_sync_telemetry(:event_refresh, Cache.latest_version(), [], :error, inspect(reason))
        {:error, reason}
    end
  end

  def refresh_since(_), do: {:error, :invalid_version}

  @spec reconcile_once() :: :ok | {:error, term()}
  def reconcile_once do
    local_version = Cache.latest_version()

    with {:ok, db_version} <- db_source().get_version() do
      if db_version > local_version do
        with {:ok, _count} <- refresh_since(local_version) do
          emit_reconcile_log(db_version, local_version, :drift_fixed)
          emit_reconcile_telemetry(db_version, local_version, :drift_fixed, nil)
          :ok
        end
      else
        emit_reconcile_log(db_version, local_version, :already_aligned)
        emit_reconcile_telemetry(db_version, local_version, :already_aligned, nil)
        :ok
      end
    else
      {:error, reason} ->
        emit_reconcile_log(nil, local_version, :db_unavailable, reason)
        emit_reconcile_telemetry(nil, local_version, :db_unavailable, inspect(reason))
        {:error, reason}
    end
  end

  defp increase_failure(state, reason, error) do
    count = state.failure_count + 1
    threshold = failure_threshold()

    if count >= threshold do
      Logger.warning(
        "ops_policy sync failed consecutive=#{count} threshold=#{threshold} reason=#{reason} error=#{inspect(error)}"
      )
    end

    %{state | failure_count: count}
  end

  defp schedule_reconcile do
    delay_ms = max(reconcile_interval_ms() + random_jitter_ms(), 0)
    Process.send_after(self(), :reconcile, delay_ms)
  end

  defp reconcile_interval_ms do
    Application.get_env(:men, :ops_policy, [])
    |> Keyword.get(:reconcile_interval_ms, @default_interval_ms)
    |> normalize_positive(@default_interval_ms)
  end

  defp random_jitter_ms do
    max_jitter =
      Application.get_env(:men, :ops_policy, [])
      |> Keyword.get(:reconcile_jitter_ms, @default_jitter_ms)
      |> normalize_non_negative(@default_jitter_ms)

    if max_jitter == 0 do
      0
    else
      :rand.uniform(max_jitter * 2 + 1) - max_jitter - 1
    end
  end

  defp failure_threshold do
    Application.get_env(:men, :ops_policy, [])
    |> Keyword.get(:reconcile_failure_threshold, @default_failure_threshold)
    |> normalize_positive(@default_failure_threshold)
  end

  defp normalize_positive(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive(_value, default), do: default

  defp normalize_non_negative(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_non_negative(_value, default), do: default

  defp emit_reconcile_log(db_version, cache_version, result, reason \\ nil) do
    Logger.info(
      "ops_policy reconcile result=#{result} db_version=#{inspect(db_version)} cache_version=#{cache_version} reason=#{inspect(reason)}"
    )
  end

  defp emit_sync_telemetry(action, version, records, result, reason) do
    :telemetry.execute(
      [:men, :ops, :policy, :sync, action],
      %{count: length(records)},
      %{
        policy_version: version,
        source: :db,
        cache_hit: false,
        reconcile_result: result,
        fallback_reason: reason
      }
    )
  rescue
    _ -> :ok
  end

  defp emit_reconcile_telemetry(db_version, cache_version, result, reason) do
    :telemetry.execute(
      [:men, :ops, :policy, :sync, :reconcile],
      %{count: 1},
      %{
        policy_version: db_version || cache_version,
        source: :db,
        cache_hit: false,
        reconcile_result: result,
        fallback_reason: reason
      }
    )
  rescue
    _ -> :ok
  end

  defp db_source do
    Application.get_env(:men, :ops_policy, [])
    |> Keyword.get(:db_source, Men.Ops.Policy.Source.DB)
  end

  defp sync_enabled? do
    Application.get_env(:men, :ops_policy, [])
    |> Keyword.get(:sync_enabled, true)
  end
end
