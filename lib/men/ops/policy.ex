defmodule Men.Ops.Policy do
  @moduledoc """
  Ops Policy 统一读取入口。
  """

  require Logger

  alias Men.Ops.Policy.Cache
  alias Men.Ops.Policy.Events

  @type identity :: Men.Ops.Policy.Source.identity()

  @type get_result :: %{
          value: map(),
          version: non_neg_integer(),
          source: :db | :ets | :config,
          cache_hit: boolean(),
          fallback_reason: atom() | nil
        }

  @spec get(identity() | keyword() | map(), keyword()) :: {:ok, get_result()} | {:error, term()}
  def get(identity, opts \\ []) do
    with {:ok, normalized} <- normalize_identity(identity) do
      do_get(normalized, opts)
    end
  end

  @spec put(identity() | keyword() | map(), map(), keyword()) ::
          {:ok, get_result()} | {:error, term()}
  def put(identity, value, opts \\ [])

  def put(identity, value, opts) when is_map(value) do
    with {:ok, normalized} <- normalize_identity(identity),
         {:ok, record} <- db_source().upsert(normalized, value, opts),
         :ok <- Cache.put(normalized, record),
         :ok <- Events.publish_changed(record.policy_version) do
      result = build_result(record.value, record.policy_version, :db, false, nil)
      emit_get_observability(normalized, result)
      {:ok, result}
    end
  end

  def put(_identity, _value, _opts), do: {:error, :invalid_value}

  defp do_get(identity, _opts) do
    case Cache.get(identity) do
      {:hit, entry} ->
        result = build_result(entry.value, entry.policy_version, :ets, true, nil)
        emit_get_observability(identity, result)
        {:ok, result}

      {:expired, entry} ->
        case db_source().fetch(identity) do
          {:ok, record} ->
            :ok = Cache.put(identity, record)
            result = build_result(record.value, record.policy_version, :db, false, nil)
            emit_get_observability(identity, result)
            {:ok, result}

          {:error, _reason} ->
            result =
              build_result(
                entry.value,
                entry.policy_version,
                :ets,
                true,
                :db_unavailable_use_expired_cache
              )

            emit_get_observability(identity, result)
            {:ok, result}
        end

      :miss ->
        from_db_or_fallback(identity)
    end
  end

  defp from_db_or_fallback(identity) do
    case db_source().fetch(identity) do
      {:ok, record} ->
        :ok = Cache.put(identity, record)
        result = build_result(record.value, record.policy_version, :db, false, nil)
        emit_get_observability(identity, result)
        {:ok, result}

      {:error, db_reason} ->
        case config_source().fetch(identity) do
          {:ok, record} ->
            result =
              build_result(
                record.value,
                record.policy_version,
                :config,
                false,
                :db_unavailable_no_cache
              )

            emit_get_observability(identity, result)
            {:ok, result}

          {:error, config_reason} ->
            {:error, {:policy_unavailable, db_reason, config_reason}}
        end
    end
  end

  defp normalize_identity(%{tenant: tenant, env: env, scope: scope, policy_key: key})
       when is_binary(tenant) and tenant != "" and is_binary(env) and env != "" and
              is_binary(scope) and scope != "" and is_binary(key) and key != "" do
    {:ok, %{tenant: tenant, env: env, scope: scope, policy_key: key}}
  end

  defp normalize_identity(identity) when is_list(identity),
    do: normalize_identity(Map.new(identity))

  defp normalize_identity(_), do: {:error, :invalid_identity}

  defp build_result(value, version, source, cache_hit, fallback_reason) do
    %{
      value: value || %{},
      version: version,
      source: source,
      cache_hit: cache_hit,
      fallback_reason: fallback_reason
    }
  end

  defp emit_get_observability(identity, result) do
    Logger.info(
      "ops_policy get tenant=#{identity.tenant} env=#{identity.env} scope=#{identity.scope} key=#{identity.policy_key} " <>
        "policy_version=#{result.version} source=#{result.source} cache_hit=#{result.cache_hit} fallback_reason=#{inspect(result.fallback_reason)}"
    )

    if telemetry_enabled?() do
      :telemetry.execute(
        [:men, :ops, :policy, :get],
        %{count: 1},
        %{
          tenant: identity.tenant,
          env: identity.env,
          scope: identity.scope,
          policy_key: identity.policy_key,
          policy_version: result.version,
          source: result.source,
          cache_hit: result.cache_hit,
          reconcile_result: :n_a,
          fallback_reason: result.fallback_reason
        }
      )
    end
  rescue
    _ -> :ok
  end

  defp telemetry_enabled? do
    Application.get_env(:men, :ops_policy, [])
    |> Keyword.get(:telemetry_enabled, true)
  end

  defp db_source do
    Application.get_env(:men, :ops_policy, [])
    |> Keyword.get(:db_source, Men.Ops.Policy.Source.DB)
  end

  defp config_source do
    Application.get_env(:men, :ops_policy, [])
    |> Keyword.get(:config_source, Men.Ops.Policy.Source.Config)
  end
end
