defmodule Men.Ops.PolicyTest do
  use Men.DataCase, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Men.Ops.Policy
  alias Men.Ops.Policy.Cache
  alias Men.Ops.Policy.Source.DB

  defmodule DBTimeoutSource do
    @behaviour Men.Ops.Policy.Source

    @impl true
    def fetch(_identity), do: {:error, :timeout}

    @impl true
    def get_version, do: {:error, :timeout}

    @impl true
    def list_since_version(_version), do: {:error, :timeout}

    @impl true
    def upsert(_identity, _value, _opts), do: {:error, :timeout}

    @impl true
    def delete(_identity, _opts), do: {:error, :timeout}
  end

  defmodule DBNotFoundSource do
    @behaviour Men.Ops.Policy.Source

    @impl true
    def fetch(_identity), do: {:error, :not_found}

    @impl true
    def get_version, do: {:ok, 0}

    @impl true
    def list_since_version(_version), do: {:ok, []}

    @impl true
    def upsert(_identity, _value, _opts), do: {:error, :not_found}

    @impl true
    def delete(_identity, _opts), do: {:error, :not_found}
  end

  setup do
    original = Application.get_env(:men, :ops_policy, [])

    Application.put_env(
      :men,
      :ops_policy,
      original
      |> Keyword.put(:db_source, DB)
      |> Keyword.put(:config_source, Men.Ops.Policy.Source.Config)
      |> Keyword.put(:cache_ttl_ms, 60_000)
      |> Keyword.put(:default_policies, %{
        {"default", "prod", "dispatch", "acl_default"} => %{"mode" => "deny_all", "allow" => []}
      })
    )

    Cache.reset()

    on_exit(fn ->
      Application.put_env(:men, :ops_policy, original)
      Cache.reset()
    end)

    :ok
  end

  test "正常读取：返回 db 值与版本" do
    identity = %{tenant: "t1", env: "prod", scope: "dispatch", policy_key: "acl_default_timeout"}

    assert {:ok, saved} =
             Policy.put(identity, %{"mode" => "strict", "allow" => ["u1"]}, updated_by: "tester")

    assert {:ok, result} = Policy.get(identity)
    assert result.value == %{"mode" => "strict", "allow" => ["u1"]}
    assert result.version == saved.version
    assert result.source in [:db, :ets]
    assert is_boolean(result.cache_hit)
  end

  test "删除策略后返回 not_found（无 config fallback）" do
    identity = %{tenant: "t1", env: "prod", scope: "dispatch", policy_key: "acl_default_timeout"}

    assert {:ok, saved} =
             Policy.put(identity, %{"mode" => "strict", "allow" => ["u1"]}, updated_by: "tester")

    assert saved.version >= 1

    assert {:ok, deleted} = Policy.delete(identity, updated_by: "tester")
    assert deleted.version > saved.version

    assert {:error, {:policy_unavailable, :not_found, :not_found}} = Policy.get(identity)
  end

  test "db 故障 + ets 可用：回退 ets 缓存并标记 fallback" do
    identity = %{tenant: "t1", env: "prod", scope: "dispatch", policy_key: "acl_default"}

    record = %{
      tenant: "t1",
      env: "prod",
      scope: "dispatch",
      policy_key: "acl_default",
      value: %{"mode" => "cached"},
      policy_version: 11,
      updated_by: "tester",
      updated_at: DateTime.utc_now()
    }

    assert :ok = Cache.put(identity, record, ttl_ms: 1)
    Process.sleep(5)

    Application.put_env(
      :men,
      :ops_policy,
      Application.get_env(:men, :ops_policy, []) |> Keyword.put(:db_source, DBTimeoutSource)
    )

    assert {:ok, result} = Policy.get(identity)
    assert result.source == :ets
    assert result.value == %{"mode" => "cached"}
    assert result.fallback_reason == :db_unavailable_use_expired_cache
  end

  test "db 故障 + ets 为空：回退 config 默认值（fail-closed）" do
    identity = %{tenant: "t1", env: "prod", scope: "dispatch", policy_key: "acl_default"}

    Application.put_env(
      :men,
      :ops_policy,
      Application.get_env(:men, :ops_policy, []) |> Keyword.put(:db_source, DBTimeoutSource)
    )

    assert {:ok, result} = Policy.get(identity)
    assert result.source == :config
    assert result.version == 0
    assert result.value["mode"] == "deny_all"
    assert result.fallback_reason == :db_unavailable_no_cache
  end

  test "db 故障 + 非 default tenant + ets 为空：回退 default tenant 配置" do
    identity = %{tenant: "tenant-x", env: "prod", scope: "dispatch", policy_key: "acl_default"}

    Application.put_env(
      :men,
      :ops_policy,
      Application.get_env(:men, :ops_policy, []) |> Keyword.put(:db_source, DBTimeoutSource)
    )

    assert {:ok, result} = Policy.get(identity)
    assert result.source == :config
    assert result.value["mode"] == "deny_all"
  end

  test "ets 过期 + db not_found：不返回过期缓存，回退 config" do
    identity = %{tenant: "t1", env: "prod", scope: "dispatch", policy_key: "acl_default"}

    record = %{
      tenant: "t1",
      env: "prod",
      scope: "dispatch",
      policy_key: "acl_default",
      value: %{"mode" => "stale-cache"},
      policy_version: 21,
      updated_by: "tester",
      updated_at: DateTime.utc_now()
    }

    assert :ok = Cache.put(identity, record, ttl_ms: 1)
    Process.sleep(5)

    Application.put_env(
      :men,
      :ops_policy,
      Application.get_env(:men, :ops_policy, []) |> Keyword.put(:db_source, DBNotFoundSource)
    )

    assert {:ok, result} = Policy.get(identity)
    assert result.source == :config
    assert result.value["mode"] == "deny_all"
    refute result.value["mode"] == "stale-cache"
    assert result.fallback_reason == :db_not_found_use_config
  end

  test "边界输入：非法 identity 与非法 value 返回错误" do
    assert {:error, :invalid_identity} = Policy.get(%{tenant: "", env: "prod", scope: "dispatch"})
    assert {:error, :invalid_identity} = Policy.get(%{tenant: "t1"})
    assert {:error, :invalid_identity} = Policy.put(%{tenant: "t1"}, %{"mode" => "x"})

    identity = %{tenant: "t1", env: "prod", scope: "dispatch", policy_key: "acl_default"}
    assert {:error, :invalid_value} = Policy.put(identity, "not-a-map")
    assert {:error, :invalid_value} = Policy.put(identity, nil)
  end

  test "并发同键写入：版本最终收敛到最大值" do
    identity = %{tenant: "t1", env: "prod", scope: "dispatch", policy_key: "acl_default"}

    versions =
      1..12
      |> Task.async_stream(
        fn i ->
          {:ok, result} =
            Policy.put(identity, %{"mode" => "strict-#{i}", "allow" => ["u#{i}"]},
              updated_by: "u#{i}"
            )

          result.version
        end,
        timeout: 5_000,
        max_concurrency: 12,
        ordered: false
      )
      |> Enum.map(fn {:ok, version} -> version end)

    max_version = Enum.max(versions)
    assert Cache.latest_version() == max_version
    assert {:ok, final} = Policy.get(identity)
    assert final.version == max_version
  end

  test "并发读写：读取结果始终可用且版本非负" do
    identity = %{tenant: "t1", env: "prod", scope: "dispatch", policy_key: "acl_default"}
    assert {:ok, _} = Policy.put(identity, %{"mode" => "seed"}, updated_by: "seed")

    writes =
      Task.async_stream(
        1..8,
        fn i ->
          Policy.put(identity, %{"mode" => "rw-#{i}"}, updated_by: "rw#{i}")
        end,
        timeout: 5_000,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.to_list()

    reads =
      Task.async_stream(
        1..8,
        fn _ ->
          Policy.get(identity)
        end,
        timeout: 5_000,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.to_list()

    assert Enum.all?(writes, fn {:ok, {:ok, result}} -> result.version >= 1 end)

    assert Enum.all?(reads, fn {:ok, {:ok, result}} ->
             is_map(result.value) and result.version >= 1
           end)
  end

  test "观测字段完整：读取日志包含 policy_version/source/cache_hit" do
    identity = %{tenant: "t1", env: "prod", scope: "dispatch", policy_key: "acl_default"}
    assert {:ok, _} = Policy.put(identity, %{"mode" => "strict"}, updated_by: "tester")

    previous_level = Logger.level()
    Logger.configure(level: :info)

    log =
      try do
        capture_log(fn ->
          assert {:ok, _result} = Policy.get(identity)
        end)
      after
        Logger.configure(level: previous_level)
      end

    assert log =~ "policy_version="
    assert log =~ "source="
    assert log =~ "cache_hit="
  end
end
