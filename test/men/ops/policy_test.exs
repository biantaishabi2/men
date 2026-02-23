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
        {"t1", "prod", "dispatch", "acl_default"} => %{"mode" => "deny_all", "allow" => []}
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
