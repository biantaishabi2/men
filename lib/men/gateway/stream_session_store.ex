defmodule Men.Gateway.StreamSessionStore do
  @moduledoc """
  流式会话状态存储（ETS）。

  用于维护 run_id 到卡片实例引用的映射，为钉钉流式卡片更新提供状态基础。
  """

  @table :men_stream_session_store

  @type stream_ref :: %{
          card_instance_id: String.t(),
          target: term(),
          channel: String.t() | nil,
          updated_at_ms: non_neg_integer()
        }

  @spec put(binary(), map()) :: :ok
  def put(run_id, attrs) when is_binary(run_id) and run_id != "" and is_map(attrs) do
    ensure_table!()

    data =
      attrs
      |> Map.put_new(:updated_at_ms, now_ms())

    :ets.insert(@table, {run_id, data})
    :ok
  end

  @spec get(binary()) :: {:ok, stream_ref()} | :error
  def get(run_id) when is_binary(run_id) and run_id != "" do
    ensure_table!()

    case :ets.lookup(@table, run_id) do
      [{^run_id, data}] when is_map(data) -> {:ok, data}
      _ -> :error
    end
  end

  @spec delete(binary()) :: :ok
  def delete(run_id) when is_binary(run_id) and run_id != "" do
    ensure_table!()
    :ets.delete(@table, run_id)
    :ok
  end

  @spec cleanup_older_than(pos_integer()) :: non_neg_integer()
  def cleanup_older_than(max_age_ms) when is_integer(max_age_ms) and max_age_ms > 0 do
    ensure_table!()
    now = now_ms()

    stale_keys =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_run_id, data} ->
        updated_at = Map.get(data, :updated_at_ms, 0)
        now - updated_at >= max_age_ms
      end)
      |> Enum.map(fn {run_id, _data} -> run_id end)

    Enum.each(stale_keys, &:ets.delete(@table, &1))
    length(stale_keys)
  end

  @doc false
  def __reset_for_test__ do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        _ = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
