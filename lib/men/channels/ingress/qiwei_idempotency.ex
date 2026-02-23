defmodule Men.Channels.Ingress.QiweiIdempotency do
  @moduledoc """
  企微 callback 幂等：同 key 短窗内重复请求返回首次响应。
  """

  require Logger

  alias Men.Channels.Ingress.QiweiAdapter

  @default_ttl_seconds 120
  @wait_interval_ms 20
  @wait_max_attempts 50
  @pending_state :pending

  @type response_payload :: %{type: :success} | %{type: :xml, body: binary()}

  defmodule Backend do
    @moduledoc false

    @callback get(binary()) :: {:ok, term() | nil} | {:error, term()}
    @callback put_if_absent(binary(), term(), pos_integer()) ::
                :ok | {:error, :exists} | {:error, term()}
    @callback put(binary(), term(), pos_integer()) :: :ok | {:error, term()}
  end

  defmodule Backend.ETS do
    @moduledoc false
    @behaviour Men.Channels.Ingress.QiweiIdempotency.Backend

    @table :men_qiwei_idempotency
    @owner_name :men_qiwei_idempotency_owner

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

    @impl true
    def put(key, value, ttl_seconds) when ttl_seconds > 0 do
      ensure_table!()
      now = System.system_time(:second)
      cleanup_expired(now)
      :ets.insert(@table, {key, value, now + ttl_seconds})
      :ok
    end

    defp ensure_table! do
      case :ets.whereis(@table) do
        :undefined ->
          ensure_owner!()

        _ ->
          :ok
      end
    end

    defp ensure_owner! do
      case Process.whereis(@owner_name) do
        nil ->
          parent = self()
          spawn(fn -> start_owner(parent) end)

          receive do
            :owner_ready -> :ok
            :owner_exists -> :ok
          after
            100 -> ensure_owner!()
          end

        _pid ->
          :ok
      end
    end

    defp start_owner(parent) do
      try do
        Process.register(self(), @owner_name)
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        send(parent, :owner_ready)
        owner_loop()
      rescue
        # 已有其他进程抢先创建 owner。
        ArgumentError -> send(parent, :owner_exists)
      end
    end

    defp owner_loop do
      receive do
        :stop -> :ok
        _ -> owner_loop()
      end
    end

    defp cleanup_expired(now) do
      :ets.select_delete(@table, [{{:"$1", :"$2", :"$3"}, [{:"=<", :"$3", now}], [true]}])
      :ok
    end
  end

  defmodule Backend.Redis do
    @moduledoc false
    @behaviour Men.Channels.Ingress.QiweiIdempotency.Backend

    @default_timeout_ms 1_000

    @impl true
    def get(key) do
      with {:ok, redix} <- ensure_redix(),
           {:ok, conn, timeout_ms} <- start_conn(redix),
           {:ok, result} <- command(redix, conn, ["GET", key], timeout_ms) do
        case result do
          nil -> {:ok, nil}
          value when is_binary(value) -> decode_value(value)
          _ -> {:error, :invalid_redis_response}
        end
      end
    end

    @impl true
    def put_if_absent(key, value, ttl_seconds) when ttl_seconds > 0 do
      with {:ok, redix} <- ensure_redix(),
           {:ok, conn, timeout_ms} <- start_conn(redix),
           encoded <- encode_value(value),
           {:ok, result} <-
             command(
               redix,
               conn,
               ["SET", key, encoded, "EX", Integer.to_string(ttl_seconds), "NX"],
               timeout_ms
             ) do
        case result do
          "OK" -> :ok
          nil -> {:error, :exists}
          _ -> {:error, :invalid_redis_response}
        end
      end
    end

    @impl true
    def put(key, value, ttl_seconds) when ttl_seconds > 0 do
      with {:ok, redix} <- ensure_redix(),
           {:ok, conn, timeout_ms} <- start_conn(redix),
           encoded <- encode_value(value),
           {:ok, "OK"} <-
             command(
               redix,
               conn,
               ["SET", key, encoded, "EX", Integer.to_string(ttl_seconds)],
               timeout_ms
             ) do
        :ok
      else
        {:ok, _other} -> {:error, :invalid_redis_response}
        {:error, reason} -> {:error, reason}
      end
    end

    defp ensure_redix do
      if Code.ensure_loaded?(Redix) do
        {:ok, Redix}
      else
        {:error, :redix_unavailable}
      end
    end

    defp start_conn(redix) do
      config = Application.get_env(:men, __MODULE__, [])
      timeout_ms = Keyword.get(config, :timeout_ms, @default_timeout_ms)

      start_opts =
        case Keyword.get(config, :url) do
          url when is_binary(url) and url != "" ->
            [url: url]

          _ ->
            [
              host: Keyword.get(config, :host, "127.0.0.1"),
              port: Keyword.get(config, :port, 6379),
              password: Keyword.get(config, :password),
              database: Keyword.get(config, :database, 0)
            ]
        end

      case redix.start_link(start_opts) do
        {:ok, conn} -> {:ok, conn, timeout_ms}
        {:error, reason} -> {:error, reason}
      end
    end

    defp command(redix, conn, args, timeout_ms) do
      try do
        redix.command(conn, args, timeout: timeout_ms)
      after
        Process.exit(conn, :normal)
      end
    end

    defp encode_value(value), do: value |> :erlang.term_to_binary() |> Base.encode64()

    defp decode_value(value) do
      with {:ok, raw} <- Base.decode64(value),
           decoded <- :erlang.binary_to_term(raw, [:safe]) do
        {:ok, decoded}
      else
        _ -> {:error, :invalid_cached_payload}
      end
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
        {:ok, %{} = cached_or_marker} ->
          cond do
            response_payload?(cached_or_marker) ->
              cached_or_marker

            pending_marker?(cached_or_marker) ->
              wait_for_response_or_run(backend, key, ttl_seconds, callback)

            true ->
              claim_and_evaluate(backend, key, ttl_seconds, callback)
          end

        {:ok, _other} ->
          claim_and_evaluate(backend, key, ttl_seconds, callback)

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

  defp claim_and_evaluate(backend, key, ttl_seconds, callback) do
    case backend_put_if_absent(backend, key, pending_marker(), ttl_seconds) do
      :ok ->
        response = callback.()

        case backend_put(backend, key, response, ttl_seconds) do
          :ok ->
            response

          {:error, reason} ->
            Logger.warning("qiwei.idempotency.backend_put_failed",
              reason: inspect(reason),
              key: key
            )

            response
        end

      {:error, :exists} ->
        wait_for_response_or_run(backend, key, ttl_seconds, callback)

      {:error, reason} ->
        Logger.warning("qiwei.idempotency.backend_put_if_absent_failed",
          reason: inspect(reason),
          key: key
        )

        callback.()
    end
  end

  defp wait_for_response_or_run(
         backend,
         key,
         ttl_seconds,
         callback,
         attempts \\ @wait_max_attempts
       )

  defp wait_for_response_or_run(_backend, _key, _ttl_seconds, callback, attempts)
       when attempts <= 0 do
    callback.()
  end

  defp wait_for_response_or_run(backend, key, ttl_seconds, callback, attempts) do
    case backend_get(backend, key) do
      {:ok, %{} = cached_or_marker} ->
        cond do
          response_payload?(cached_or_marker) ->
            cached_or_marker

          pending_marker?(cached_or_marker) ->
            Process.sleep(@wait_interval_ms)
            wait_for_response_or_run(backend, key, ttl_seconds, callback, attempts - 1)

          true ->
            claim_and_evaluate(backend, key, ttl_seconds, callback)
        end

      {:ok, _other} ->
        claim_and_evaluate(backend, key, ttl_seconds, callback)

      {:error, reason} ->
        Logger.warning("qiwei.idempotency.backend_wait_failed", reason: inspect(reason), key: key)
        callback.()
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

  defp backend_put(backend, key, value, ttl_seconds) do
    _ = Code.ensure_loaded(backend)

    if function_exported?(backend, :put, 3) do
      backend.put(key, value, ttl_seconds)
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

  defp response_payload?(%{type: :success}), do: true
  defp response_payload?(%{type: :xml, body: body}) when is_binary(body), do: true
  defp response_payload?(_), do: false

  defp pending_marker do
    %{__state__: @pending_state, ts: System.system_time(:millisecond)}
  end

  defp pending_marker?(%{__state__: @pending_state}), do: true
  defp pending_marker?(_), do: false
end
