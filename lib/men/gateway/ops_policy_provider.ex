defmodule Men.Gateway.OpsPolicyProvider do
  @moduledoc """
  网关运行策略提供器：优先读取 Ops Policy，并在本地 ETS 做短期缓存。
  """

  require Logger

  @table :men_gateway_ops_policy_cache
  @default_cache_ttl_ms 300_000

  @type policy :: %{
          acl: map(),
          wake: map(),
          dedup_ttl_ms: pos_integer(),
          version: non_neg_integer(),
          policy_version: String.t()
        }

  @spec get_policy(keyword() | map()) :: {:ok, policy()}
  def get_policy(opts \\ []) do
    options = normalize_opts(opts)
    ensure_table()

    case read_cache(options) do
      {:ok, cached} ->
        {:ok, cached}

      :expired ->
        refresh_policy(options)

      :miss ->
        refresh_policy(options)
    end
  end

  @spec reset_cache() :: :ok
  def reset_cache do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp refresh_policy(options) do
    cached = read_cache_raw()

    case fetch_remote_policy(options) do
      {:ok, remote} ->
        resolved = choose_newer_policy(cached, remote)
        write_cache(resolved, options)
        {:ok, resolved}

      {:error, reason} ->
        fallback = fallback_policy(options, reason)
        write_cache(fallback, options)
        {:ok, fallback}
    end
  end

  defp choose_newer_policy(:miss, remote), do: remote

  defp choose_newer_policy(cached, remote) do
    if remote.version >= cached.version, do: remote, else: cached
  end

  defp fetch_remote_policy(options) do
    identity = Map.get(options, :identity, default_identity())
    ops_policy_module = Module.concat([Men, OpsPolicy])

    cond do
      Code.ensure_loaded?(ops_policy_module) and
          function_exported?(ops_policy_module, :get_policy, 1) ->
        case apply(ops_policy_module, :get_policy, [identity]) do
          {:ok, policy} -> normalize_policy(policy, options)
          {:error, reason} -> {:error, reason}
          policy when is_map(policy) -> normalize_policy(policy, options)
          other -> {:error, {:unexpected_policy_result, other}}
        end

      Code.ensure_loaded?(Men.Ops.Policy) and function_exported?(Men.Ops.Policy, :get, 2) ->
        policy_key = Map.get(options, :policy_key, "gateway_runtime")

        case Men.Ops.Policy.get(Map.put(identity, :policy_key, policy_key), []) do
          {:ok, result} ->
            normalize_policy(
              %{
                "acl" => Map.get(result.value, "acl"),
                "wake" => Map.get(result.value, "wake"),
                "dedup_ttl_ms" => Map.get(result.value, "dedup_ttl_ms"),
                "version" => result.version,
                "policy_version" => Integer.to_string(result.version)
              },
              options
            )

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:error, :ops_policy_unavailable}
    end
  rescue
    error -> {:error, {:exception, error}}
  end

  defp normalize_policy(policy, options) do
    merged =
      fallback_policy(options, :normalize_seed)
      |> Map.merge(string_or_atom_map(policy))

    with {:ok, acl} <- normalize_acl(Map.get(merged, "acl") || Map.get(merged, :acl)),
         {:ok, wake} <- normalize_wake(Map.get(merged, "wake") || Map.get(merged, :wake)),
         {:ok, dedup_ttl_ms} <-
           normalize_ttl(Map.get(merged, "dedup_ttl_ms") || Map.get(merged, :dedup_ttl_ms)),
         {:ok, version} <-
           normalize_version(Map.get(merged, "version") || Map.get(merged, :version)),
         {:ok, policy_version} <-
           normalize_policy_version(
             Map.get(merged, "policy_version") || Map.get(merged, :policy_version),
             version
           ) do
      {:ok,
       %{
         acl: acl,
         wake: wake,
         dedup_ttl_ms: dedup_ttl_ms,
         version: version,
         policy_version: policy_version
       }}
    end
  end

  defp normalize_acl(%{} = acl), do: {:ok, acl}
  defp normalize_acl(_), do: {:error, :invalid_acl}

  defp normalize_wake(%{} = wake), do: {:ok, wake}
  defp normalize_wake(_), do: {:error, :invalid_wake}

  defp normalize_ttl(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp normalize_ttl(_), do: {:error, :invalid_dedup_ttl_ms}

  defp normalize_version(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp normalize_version(_), do: {:error, :invalid_version}

  defp normalize_policy_version(value, _version) when is_binary(value) and value != "",
    do: {:ok, value}

  defp normalize_policy_version(value, _version) when is_integer(value) and value >= 0,
    do: {:ok, Integer.to_string(value)}

  defp normalize_policy_version(_, version), do: {:ok, Integer.to_string(version)}

  defp read_cache(_options) do
    case read_cache_raw() do
      :miss ->
        :miss

      cached ->
        if cached.expire_at_ms >= now_ms() do
          {:ok, Map.drop(cached, [:expire_at_ms])}
        else
          :expired
        end
    end
  end

  defp read_cache_raw do
    ensure_table()

    case :ets.lookup(@table, :policy) do
      [{:policy, cached}] when is_map(cached) -> cached
      _ -> :miss
    end
  end

  defp write_cache(policy, options) do
    ttl_ms = Map.get(options, :cache_ttl_ms, configured_cache_ttl_ms())

    entry =
      policy
      |> Map.put(:expire_at_ms, now_ms() + ttl_ms)

    :ets.insert(@table, {:policy, entry})
    :ok
  end

  defp configured_cache_ttl_ms do
    Application.get_env(:men, __MODULE__, [])
    |> Keyword.get(:cache_ttl_ms, @default_cache_ttl_ms)
    |> normalize_positive_integer(@default_cache_ttl_ms)
  end

  defp fallback_policy(_options, reason) do
    bootstrap =
      Application.get_env(:men, __MODULE__, [])
      |> Keyword.get(:bootstrap_policy, %{})
      |> normalize_bootstrap()

    base = default_policy()

    # 降级时始终采用最严格策略，避免越权放行。
    merged =
      Map.merge(base, bootstrap) |> Map.put(:policy_version, "fallback") |> Map.put(:version, 0)

    if reason != :normalize_seed do
      Logger.warning(
        "gateway.ops_policy fallback reason=#{inspect(reason)} policy_version=#{merged.policy_version}"
      )
    end

    merged
  end

  defp default_policy do
    %{
      acl: %{
        "main" => %{
          "read" => ["global.", "agent.", "shared.", "inbox."],
          "write" => ["global.control.", "inbox."]
        },
        "child" => %{
          "read" => ["agent.$agent_id.", "shared.evidence.agent.$agent_id.", "inbox."],
          "write" => ["agent.$agent_id.", "shared.evidence.agent.$agent_id.", "inbox."]
        },
        "tool" => %{
          "read" => ["agent.$agent_id.", "shared.evidence.agent.$agent_id.", "inbox."],
          "write" => ["inbox."]
        },
        "system" => %{
          "read" => [""],
          "write" => [""]
        }
      },
      wake: %{
        "must_wake" => ["agent_result", "agent_error", "policy_changed"],
        "inbox_only" => ["heartbeat", "tool_progress", "telemetry"]
      },
      dedup_ttl_ms: 60_000,
      version: 0,
      policy_version: "fallback"
    }
  end

  defp default_identity do
    %{
      tenant: "default",
      env: "prod",
      scope: "gateway"
    }
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(_), do: %{}

  defp string_or_atom_map(%{} = map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      normalized_key =
        case key do
          k when is_binary(k) -> k
          k when is_atom(k) -> k
          _ -> key
        end

      Map.put(acc, normalized_key, value)
    end)
  end

  defp string_or_atom_map(_), do: %{}

  defp normalize_bootstrap(%{} = bootstrap) do
    %{
      acl: Map.get(bootstrap, :acl) || Map.get(bootstrap, "acl") || %{},
      wake: Map.get(bootstrap, :wake) || Map.get(bootstrap, "wake") || %{},
      dedup_ttl_ms:
        Map.get(bootstrap, :dedup_ttl_ms) || Map.get(bootstrap, "dedup_ttl_ms") || 60_000,
      version: Map.get(bootstrap, :version) || Map.get(bootstrap, "version") || 0,
      policy_version:
        Map.get(bootstrap, :policy_version) || Map.get(bootstrap, "policy_version") || "fallback"
    }
  end

  defp normalize_bootstrap(_), do: %{}

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_, default), do: default

  defp now_ms, do: System.system_time(:millisecond)
end
