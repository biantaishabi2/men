defmodule Men.BDD.OpsPolicyFeatureTest do
  use Men.DataCase, async: false

  alias Men.Ops.Policy
  alias Men.Ops.Policy.Cache
  alias Men.Ops.Policy.Events
  alias Men.Ops.Policy.Source.DB
  alias Men.Ops.Policy.Sync

  @moduletag :bdd

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
    sync_name = {:global, {__MODULE__, self(), make_ref()}}
    start_supervised!({Sync, name: sync_name, enabled: true})

    on_exit(fn ->
      Application.put_env(:men, :ops_policy, original)
      Cache.reset()
    end)

    :ok
  end

  test "BDD: DB 更新后节点读取最终一致" do
    # Given: 初始策略写入 DB，并先读一次建立本地缓存。
    identity = %{tenant: "t1", env: "prod", scope: "dispatch", policy_key: "acl_default"}

    assert {:ok, _v1} =
             DB.upsert(identity, %{"mode" => "strict-v1", "allow" => ["u1"]}, updated_by: "bdd")

    assert {:ok, warmup} = Policy.get(identity)
    assert warmup.value["mode"] == "strict-v1"

    # When: DB 热更新并发布 policy_changed 事件。
    assert {:ok, v2} =
             DB.upsert(identity, %{"mode" => "strict-v2", "allow" => ["u1", "u2"]},
               updated_by: "bdd"
             )

    assert :ok = Events.publish_changed(v2.policy_version)

    # Then: 节点读取应收敛到新版本。
    assert_eventually(fn ->
      case Policy.get(identity) do
        {:ok, result} ->
          result.version == v2.policy_version and result.value["mode"] == "strict-v2"

        _ ->
          false
      end
    end)
  end

  defp assert_eventually(fun, attempts \\ 40)
  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end
end
