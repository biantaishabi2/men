defmodule Men.Channels.Ingress.QiweiIdempotency do
  @moduledoc """
  企微 callback 幂等：同 key 短窗内重复请求返回首次响应。
  """

  require Logger

  alias Men.Channels.Ingress.QiweiAdapter

  @default_ttl_seconds 120

  @type response_payload :: %{type: :success} | %{type: :xml, body: binary()}

  defmodule Backend do
    @moduledoc false

    @callback get(binary()) :: {:ok, term() | nil} | {:error, term()}
    @callback put_if_absent(binary(), term(), pos_integer()) ::
                :ok | {:error, :exists} | {:error, term()}
  end

  defmodule Backend.ETS do
    @moduledoc false
    @behaviour Men.Channels.Ingress.QiweiIdempotency.Backend

    @table :men_qiwei_idempotency

    @impl true
    def get(key) do
      ensure_table!()
      cleanup_expired(System.system_time(:second))

      case :ets.lookup(@table, key) do
        [{^key, value, _expires_at}] -> {:ok, value}
        _ -> {:ok, nil}
      end
    end

    @impl true
    def put_if_absent(key, value, ttl_seconds) when ttl_seconds > 0 do
      ensure_table!()
      now = System.system_time(:second)
      cleanup_expired(now)

      record = {key, value, now + ttl_seconds}

      if :ets.insert_new(@table, record), do: :ok, else: {:error, :exists}
    end

    defp ensure_table! do
      case :ets.whereis(@table) do
        :undefined ->
          try do
            :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          rescue
            # 并发创建竞争时重试即可。
            ArgumentError -> ensure_table!()
          end

        _ ->
          :ok
      end
    end

    defp cleanup_expired(now) do
      :ets.select_delete(@table, [{{:"$1", :"$2", :"$3"}, [{:"=<", :"$3", now}], [true]}])
      :ok
    end
  end

  @spec with_idempotency(map(), (-> response_payload()), keyword()) :: response_payload()
  def with_idempotency(inbound_event, callback, opts \\ [])
      when is_map(inbound_event) and is_function(callback, 0) do
    key = key(inbound_event)
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    backend = Keyword.get(opts, :backend, Backend.ETS)

    if is_binary(key) and key != "" do
      case backend_get(backend, key) do
        {:ok, %{} = cached_response} ->
          cached_response

        {:ok, _} ->
          evaluate_and_cache(backend, key, ttl_seconds, callback)

        {:error, reason} ->
          Logger.warning("qiwei.idempotency.backend_get_failed",
            reason: inspect(reason),
            key: key
          )

          callback.()
      end
    else
      callback.()
    end
  end

  @spec key(map()) :: binary() | nil
  def key(inbound_event) when is_map(inbound_event) do
    fp = QiweiAdapter.idempotency_fingerprint(inbound_event)

    cond do
      present?(fp[:corp_id]) and present?(fp[:agent_id]) and present?(fp[:msg_id]) ->
        join_key(["qiwei", fp[:corp_id], fp[:agent_id], fp[:msg_id]])

      present?(fp[:corp_id]) and present?(fp[:agent_id]) and present?(fp[:from_user]) and
        present?(fp[:create_time]) and present?(fp[:event]) ->
        join_key([
          "qiwei",
          fp[:corp_id],
          fp[:agent_id],
          fp[:from_user],
          fp[:create_time],
          fp[:event],
          fp[:event_key] || ""
        ])

      true ->
        nil
    end
  end

  def key(_), do: nil

  defp evaluate_and_cache(backend, key, ttl_seconds, callback) do
    response = callback.()

    case backend_put_if_absent(backend, key, response, ttl_seconds) do
      :ok ->
        response

      {:error, :exists} ->
        case backend_get(backend, key) do
          {:ok, %{} = cached} -> cached
          _ -> response
        end

      {:error, reason} ->
        Logger.warning("qiwei.idempotency.backend_put_failed", reason: inspect(reason), key: key)
        response
    end
  end

  defp backend_get(backend, key) do
    _ = Code.ensure_loaded(backend)

    if function_exported?(backend, :get, 1),
      do: backend.get(key),
      else: {:error, :invalid_backend}
  end

  defp backend_put_if_absent(backend, key, value, ttl_seconds) do
    _ = Code.ensure_loaded(backend)

    if function_exported?(backend, :put_if_absent, 3) do
      backend.put_if_absent(key, value, ttl_seconds)
    else
      {:error, :invalid_backend}
    end
  end

  defp join_key(parts) do
    parts
    |> Enum.map(&to_string/1)
    |> Enum.join(":")
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_integer(value), do: true
  defp present?(_), do: false
end
