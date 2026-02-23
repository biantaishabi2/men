defmodule Men.Gateway.ReplStore do
  @moduledoc """
  REPL ETS 共享状态存储：统一处理 ACL、去重、TTL 与版本冲突。
  """

  require Logger

  alias Men.Gateway.EventEnvelope
  alias Men.Gateway.ReplAcl

  @default_state_table :men_gateway_repl_state
  @default_dedup_table :men_gateway_repl_dedup
  @default_inbox_table :men_gateway_repl_inbox
  @default_scope_table :men_gateway_repl_scope

  @type put_outcome :: :stored | :idempotent | :older_drop

  @spec put(map(), String.t(), term(), keyword() | map()) ::
          {:ok, put_outcome()} | {:error, :acl_denied | term()}
  def put(actor, key, value, opts \\ []) do
    options = normalize_opts(opts)
    policy = Map.get(options, :policy, %{})
    version = Map.get(options, :version, 0)

    with :ok <- ReplAcl.authorize_write(actor, key, policy, Map.get(options, :context, %{})),
         {:ok, state_table} <- ensure_table(Map.get(options, :state_table, @default_state_table)),
         {:ok, outcome} <- put_versioned(state_table, key, value, version) do
      {:ok, outcome}
    end
  end

  @spec get(map(), String.t(), keyword() | map()) :: {:ok, map()} | :not_found | {:error, term()}
  def get(actor, key, opts \\ []) do
    options = normalize_opts(opts)
    policy = Map.get(options, :policy, %{})

    with :ok <- ReplAcl.authorize_read(actor, key, policy, Map.get(options, :context, %{})),
         {:ok, state_table} <- ensure_table(Map.get(options, :state_table, @default_state_table)) do
      case :ets.lookup(state_table, key) do
        [{^key, row}] -> {:ok, row}
        _ -> :not_found
      end
    end
  end

  @spec list(map(), String.t(), keyword() | map()) :: {:ok, [map()]} | {:error, term()}
  def list(actor, prefix, opts \\ []) do
    options = normalize_opts(opts)
    policy = Map.get(options, :policy, %{})

    with :ok <- ReplAcl.authorize_read(actor, prefix, policy, Map.get(options, :context, %{})),
         {:ok, state_table} <- ensure_table(Map.get(options, :state_table, @default_state_table)) do
      rows =
        :ets.tab2list(state_table)
        |> Enum.map(fn {_key, row} -> row end)
        |> Enum.filter(&String.starts_with?(&1.key, prefix))

      {:ok, rows}
    end
  end

  @spec query(map(), (map() -> boolean()), keyword() | map()) :: {:ok, [map()]} | {:error, term()}
  def query(actor, fun, opts \\ []) when is_function(fun, 1) do
    options = normalize_opts(opts)
    policy = Map.get(options, :policy, %{})
    context = Map.get(options, :context, %{})

    with {:ok, state_table} <- ensure_table(Map.get(options, :state_table, @default_state_table)) do
      rows =
        :ets.tab2list(state_table)
        |> Enum.map(fn {_key, row} -> row end)
        |> Enum.filter(fn row ->
          ReplAcl.authorize_read(actor, row.key, policy, context) == :ok and fun.(row)
        end)

      {:ok, rows}
    end
  end

  @spec put_inbox(EventEnvelope.t(), map(), keyword() | map()) ::
          {:ok, %{status: :stored | :duplicate | :idempotent | :older_drop, duplicate: boolean()}}
          | {:error, term()}
  def put_inbox(%EventEnvelope{} = envelope, policy, opts \\ []) do
    options = normalize_opts(opts)
    context = inbox_context(envelope, policy)
    actor = Map.get(options, :actor, %{role: :system, session_key: envelope.session_key})
    dedup_ttl_ms = Map.get(policy, :dedup_ttl_ms) || Map.get(policy, "dedup_ttl_ms") || 60_000

    with :ok <-
           ReplAcl.authorize_write(
             actor,
             "inbox.#{envelope.session_key}.#{envelope.event_id}",
             policy,
             context
           ),
         {:ok, dedup_table} <- ensure_table(Map.get(options, :dedup_table, @default_dedup_table)),
         {:ok, inbox_table} <- ensure_table(Map.get(options, :inbox_table, @default_inbox_table)),
         {:ok, scope_table} <- ensure_table(Map.get(options, :scope_table, @default_scope_table)),
         :ok <- cleanup_expired_dedup(dedup_table),
         {:ok, duplicate?} <- put_dedup(dedup_table, envelope, dedup_ttl_ms) do
      if duplicate? do
        log_inbox_result(context, false, true, :duplicate, "duplicate")
        {:ok, %{status: :duplicate, duplicate: true}}
      else
        outcome = apply_version_guard(scope_table, envelope)
        accepted = outcome != :older_drop

        if accepted do
          :ets.insert(inbox_table, {dedup_key(envelope), envelope})
        end

        log_inbox_result(context, accepted, false, outcome, Atom.to_string(outcome))

        {:ok,
         %{
           status: normalize_inbox_status(outcome),
           duplicate: false
         }}
      end
    end
  end

  @spec latest_by_ets_keys([String.t()], keyword() | map()) ::
          {:ok, EventEnvelope.t()} | :not_found
  def latest_by_ets_keys(ets_keys, opts \\ []) when is_list(ets_keys) do
    options = normalize_opts(opts)

    with {:ok, scope_table} <- ensure_table(Map.get(options, :scope_table, @default_scope_table)) do
      case :ets.lookup(scope_table, scope_key(ets_keys)) do
        [{_scope_key, _version, envelope}] -> {:ok, envelope}
        _ -> :not_found
      end
    else
      _ -> :not_found
    end
  end

  @spec reset(keyword() | map()) :: :ok
  def reset(opts \\ []) do
    options = normalize_opts(opts)

    tables = [
      Map.get(options, :state_table, @default_state_table),
      Map.get(options, :dedup_table, @default_dedup_table),
      Map.get(options, :inbox_table, @default_inbox_table),
      Map.get(options, :scope_table, @default_scope_table)
    ]

    Enum.each(tables, fn table ->
      case ensure_table(table) do
        {:ok, tid} -> :ets.delete_all_objects(tid)
        _ -> :ok
      end
    end)

    :ok
  end

  defp put_versioned(table, key, value, version) when is_integer(version) and version >= 0 do
    case :ets.lookup(table, key) do
      [] ->
        row = %{key: key, value: value, version: version, updated_at: now_ms()}
        :ets.insert(table, {key, row})
        {:ok, :stored}

      [{^key, row}] when version > row.version ->
        new_row = %{row | value: value, version: version, updated_at: now_ms()}
        :ets.insert(table, {key, new_row})
        {:ok, :stored}

      [{^key, row}] when version == row.version ->
        {:ok, :idempotent}

      [{^key, _row}] ->
        {:ok, :older_drop}
    end
  end

  defp put_versioned(_table, _key, _value, _version), do: {:error, :invalid_version}

  defp put_dedup(table, envelope, dedup_ttl_ms) do
    key = dedup_key(envelope)
    now = now_ms()

    case :ets.lookup(table, key) do
      [{^key, expire_at}] when is_integer(expire_at) and expire_at >= now ->
        {:ok, true}

      _ ->
        :ets.insert(table, {key, now + dedup_ttl_ms})
        {:ok, false}
    end
  end

  defp cleanup_expired_dedup(table) do
    now = now_ms()

    :ets.select_delete(table, [
      {{:"$1", :"$2"}, [{:<, :"$2", now}], [true]}
    ])

    :ok
  rescue
    _ -> :ok
  end

  defp apply_version_guard(scope_table, envelope) do
    scope = scope_key(envelope.ets_keys)

    case :ets.lookup(scope_table, scope) do
      [] ->
        :ets.insert(scope_table, {scope, envelope.version, envelope})
        :stored

      [{^scope, version, _current}] when envelope.version > version ->
        :ets.insert(scope_table, {scope, envelope.version, envelope})
        :stored

      [{^scope, version, _current}] when envelope.version == version ->
        :idempotent

      [{^scope, _version, _current}] ->
        :older_drop
    end
  end

  defp log_inbox_result(context, accepted, duplicate, status, decision_reason) do
    Logger.info(
      "inbox_store_result " <>
        Jason.encode!(
          context
          |> Map.put(:accepted, accepted)
          |> Map.put(:duplicate, duplicate)
          |> Map.put(:status, status)
          |> Map.put(:decision_reason, decision_reason)
        )
    )
  rescue
    _ -> :ok
  end

  defp dedup_key(%EventEnvelope{source: source, session_key: session_key, event_id: event_id}) do
    {source, session_key, event_id}
  end

  defp scope_key(ets_keys) do
    ets_keys
    |> Enum.map(&to_string/1)
    |> List.to_tuple()
  end

  defp inbox_context(envelope, policy) do
    %{
      event_id: envelope.event_id,
      session_key: envelope.session_key,
      type: envelope.type,
      source: envelope.source,
      wake: envelope.wake,
      inbox_only: envelope.inbox_only,
      decision_reason:
        Map.get(envelope.meta, :decision_reason) || Map.get(envelope.meta, "decision_reason"),
      policy_version:
        Map.get(policy, :policy_version) || Map.get(policy, "policy_version") || "unknown"
    }
  end

  defp normalize_inbox_status(:stored), do: :stored
  defp normalize_inbox_status(:idempotent), do: :idempotent
  defp normalize_inbox_status(:older_drop), do: :older_drop

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

      _ ->
        table_name
    end

    {:ok, table_name}
  rescue
    ArgumentError -> {:error, :ets_table_init_failed}
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(_), do: %{}

  defp now_ms, do: System.system_time(:millisecond)
end
