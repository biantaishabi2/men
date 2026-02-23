defmodule Men.Integration.OpsPolicySyncTest do
  use Men.DataCase, async: false

  alias Men.Ops.Policy
  alias Men.Ops.Policy.Cache
  alias Men.Ops.Policy.Events
  alias Men.Ops.Policy.Source.DB
  alias Men.Ops.Policy.Sync

  setup do
    original = Application.get_env(:men, :ops_policy, [])

    Application.put_env(
      :men,
      :ops_policy,
      original
      |> Keyword.put(:db_source, DB)
      |> Keyword.put(:config_source, Men.Ops.Policy.Source.Config)
      |> Keyword.put(:cache_ttl_ms, 60_000)
      |> Keyword.put(:reconcile_interval_ms, 80)
      |> Keyword.put(:reconcile_jitter_ms, 0)
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

  test "热更新后事件刷新：ets 更新为新版本，跨进程读取一致" do
    identity = %{tenant: "t1", env: "prod", scope: "dispatch", policy_key: "acl_default"}

    assert {:ok, first} = DB.upsert(identity, %{"mode" => "strict-v1"}, updated_by: "u1")
    assert {:ok, _} = Policy.get(identity)

    assert {:ok, second} = DB.upsert(identity, %{"mode" => "strict-v2"}, updated_by: "u2")
    assert second.policy_version > first.policy_version
    assert :ok = Events.publish_changed(second.policy_version)

    assert_eventually(fn ->
      Cache.latest_version() >= second.policy_version
    end)

    reads =
      1..2
      |> Task.async_stream(fn _ -> Policy.get(identity) end, timeout: 2_000, max_concurrency: 2)
      |> Enum.map(fn {:ok, {:ok, result}} -> result end)

    assert Enum.all?(reads, fn result ->
             result.version == second.policy_version and result.value["mode"] == "strict-v2"
           end)
  end

  test "丢事件后对账修复：一次周期内追平版本" do
    identity = %{tenant: "t1", env: "prod", scope: "dispatch", policy_key: "acl_default"}

    assert {:ok, first} = DB.upsert(identity, %{"mode" => "strict-v1"}, updated_by: "u1")
    assert {:ok, _} = Policy.get(identity)

    assert {:ok, second} = DB.upsert(identity, %{"mode" => "strict-v2"}, updated_by: "u2")
    assert second.policy_version > first.policy_version

    assert_eventually(fn ->
      Cache.latest_version() >= second.policy_version
    end)

    assert {:ok, result} = Policy.get(identity)
    assert result.version == second.policy_version
    assert result.value["mode"] == "strict-v2"
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
