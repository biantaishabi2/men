defmodule Men.Channels.Ingress.QiweiIdempotency do
  @moduledoc """
  企微回调幂等：短窗缓存首次响应，重复投递返回一致结果。
  """

  require Logger

  @table :men_qiwei_idempotency
  @default_ttl_seconds 120
  @default_pending_poll_interval_ms 20
  @default_pending_wait_timeout_ms 5_000

  @type reply_result :: {:success} | {:xml, binary()}
  @type entry_payload :: %{status: String.t(), response: map() | nil}

  @spec fetch_or_store(map(), (-> reply_result()), keyword()) ::
          {:fresh, reply_result()} | {:duplicate, reply_result()}
  def fetch_or_store(inbound_event, producer, opts \\ [])
      when is_map(inbound_event) and is_function(producer, 0) do
    key = key(inbound_event)
    ttl = ttl_seconds(opts)
    pending_wait_timeout_ms = pending_wait_timeout_ms(opts)

    case claim_or_read(key, ttl) do
      {:owner, _entry} ->
        response = run_producer(producer, key)
        :ok = store_done(key, response, ttl)
        {:fresh, response}

      {:cached, payload} ->
        {:duplicate, decode_response(payload)}

      {:pending, _entry} ->
        case wait_for_done(key, pending_wait_timeout_ms) do
          {:ok, payload} ->
            {:duplicate, decode_response(payload)}

          :timeout ->
            Logger.warning("qiwei.idempotency.pending_wait_timeout",
              key: key,
              timeout_ms: pending_wait_timeout_ms
            )

            {:duplicate, {:success}}

          :miss ->
            Logger.warning("qiwei.idempotency.pending_missing", key: key)
            {:duplicate, {:success}}
        end
    end
  end

  @spec key(map()) :: binary()
  def key(inbound_event) when is_map(inbound_event) do
    payload = Map.get(inbound_event, :payload, %{})

    corp_id = map_value(payload, :corp_id, "unknown_corp")
    agent_id = map_value(payload, :agent_id, "unknown_agent")
    msg_type = map_value(payload, :msg_type, "unknown")

    if msg_type == "event" do
      from_user = map_value(payload, :from_user, "unknown_user")
      create_time = map_value(payload, :create_time, 0) |> to_string()
      event = map_value(payload, :event, "unknown_event")
      event_key = map_value(payload, :event_key, "")

      ["qiwei", corp_id, agent_id, from_user, create_time, event, event_key]
      |> Enum.join(":")
    else
      msg_id =
        map_value(payload, :msg_id, nil) ||
          Map.get(inbound_event, :request_id, "unknown_msg")

      ["qiwei", corp_id, agent_id, to_string(msg_id)]
      |> Enum.join(":")
    end
  end

  defp pending_entry, do: %{status: "pending", response: nil}

  defp done_entry(response), do: %{status: "done", response: encode_response(response)}

  defp encode_response({:success}), do: %{type: "success", body: ""}

  defp encode_response({:xml, body}) when is_binary(body) do
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    %{type: "xml", body: body, digest: digest}
  end

  defp encode_response(_), do: %{type: "success", body: ""}

  defp decode_response(%{"type" => "xml", "body" => body}) when is_binary(body), do: {:xml, body}
  defp decode_response(%{type: "xml", body: body}) when is_binary(body), do: {:xml, body}
  defp decode_response(_), do: {:success}

  defp claim_or_read(key, ttl_seconds) do
    now = now_ms()
    expires_at = now + ttl_seconds * 1000
    ensure_table!()

    case :ets.insert_new(@table, {key, expires_at, pending_entry()}) do
      true ->
        {:owner, pending_entry()}

      false ->
        read_existing_or_retry(key, ttl_seconds, now)
    end
  rescue
    error ->
      Logger.warning("qiwei.idempotency.claim_failed", key: key, reason: inspect(error))
      {:owner, pending_entry()}
  end

  defp read_existing_or_retry(key, ttl_seconds, now) do
    case :ets.lookup(@table, key) do
      [{^key, expires_at, payload}] when is_integer(expires_at) and expires_at > now ->
        case payload_status(payload) do
          :done -> {:cached, payload_response(payload)}
          :pending -> {:pending, payload}
        end

      [{^key, _expires_at, _payload}] ->
        :ets.delete(@table, key)

        case :ets.insert_new(@table, {key, now_ms() + ttl_seconds * 1000, pending_entry()}) do
          true -> {:owner, pending_entry()}
          false -> {:pending, pending_entry()}
        end

      _ ->
        case :ets.insert_new(@table, {key, now_ms() + ttl_seconds * 1000, pending_entry()}) do
          true -> {:owner, pending_entry()}
          false -> {:pending, pending_entry()}
        end
    end
  rescue
    error ->
      Logger.warning("qiwei.idempotency.lookup_failed", key: key, reason: inspect(error))
      {:owner, pending_entry()}
  end

  defp wait_for_done(key, wait_timeout_ms) do
    deadline = now_ms() + wait_timeout_ms
    do_wait_for_done(key, deadline)
  end

  defp do_wait_for_done(key, deadline) do
    now = now_ms()

    case lookup_entry(key, now) do
      {:done, payload} ->
        {:ok, payload_response(payload)}

      :pending when now < deadline ->
        Process.sleep(@default_pending_poll_interval_ms)
        do_wait_for_done(key, deadline)

      :pending ->
        :timeout

      :miss ->
        :miss
    end
  end

  defp lookup_entry(key, now) do
    ensure_table!()

    case :ets.lookup(@table, key) do
      [{^key, expires_at, payload}] when is_integer(expires_at) and expires_at > now ->
        case payload_status(payload) do
          :done -> {:done, payload}
          :pending -> :pending
        end

      [{^key, _expires_at, _payload}] ->
        :ets.delete(@table, key)
        :miss

      _ ->
        :miss
    end
  rescue
    error ->
      Logger.warning("qiwei.idempotency.lookup_entry_failed", key: key, reason: inspect(error))
      :miss
  end

  defp run_producer(producer, key) do
    producer.()
  rescue
    error ->
      Logger.warning("qiwei.idempotency.producer_failed", key: key, reason: inspect(error))
      {:success}
  catch
    kind, reason ->
      Logger.warning("qiwei.idempotency.producer_failed",
        key: key,
        reason: inspect({kind, reason})
      )

      {:success}
  end

  defp store_done(key, response, ttl_seconds) do
    now = now_ms()
    ensure_table!()
    expires_at = now + ttl_seconds * 1000
    true = :ets.insert(@table, {key, expires_at, done_entry(response)})
    cleanup_expired(now)
    :ok
  rescue
    error ->
      {:error, error}
  end

  defp ttl_seconds(opts) do
    Keyword.get(
      opts,
      :ttl_seconds,
      qiwei_config() |> Keyword.get(:idempotency_ttl_seconds, @default_ttl_seconds)
    )
  end

  defp pending_wait_timeout_ms(opts) do
    Keyword.get(
      opts,
      :pending_wait_timeout_ms,
      qiwei_config()
      |> Keyword.get(
        :idempotency_pending_wait_timeout_ms,
        qiwei_config() |> Keyword.get(:callback_timeout_ms, @default_pending_wait_timeout_ms)
      )
    )
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        # 使用稳定 heir，避免短生命周期请求进程退出后 ETS 表被销毁。
        heir = Process.whereis(:init)

        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          {:heir, heir, :ok},
          read_concurrency: true,
          write_concurrency: true
        ])

        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end

  # 每次写入做一次轻量清理，避免表无限增长。
  defp cleanup_expired(now) do
    :ets.select_delete(@table, [{{:"$1", :"$2", :"$3"}, [{:"=<", :"$2", now}], [true]}])
    :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp payload_status(%{"status" => "done"}), do: :done
  defp payload_status(%{status: "done"}), do: :done
  defp payload_status(_), do: :pending

  defp payload_response(%{"response" => response}), do: response
  defp payload_response(%{response: response}), do: response
  defp payload_response(_), do: %{type: "success", body: ""}

  defp qiwei_config do
    Application.get_env(:men, :qiwei, [])
  end

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_value(_map, _key, default), do: default
end
