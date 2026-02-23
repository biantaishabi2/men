defmodule Men.Gateway.OpsPolicyProviderTest do
  use ExUnit.Case, async: false

  alias Men.Gateway.OpsPolicyProvider

  setup do
    original_gateway = Application.get_env(:men, OpsPolicyProvider, [])
    original_ops_policy = Application.get_env(:men, :ops_policy, [])

    Application.put_env(:men, OpsPolicyProvider,
      cache_ttl_ms: 5,
      bootstrap_policy: %{
        acl: %{"main" => %{"read" => [], "write" => []}},
        wake: %{"must_wake" => [], "inbox_only" => ["agent_result"]},
        dedup_ttl_ms: 10_000
      }
    )

    Application.put_env(
      :men,
      :ops_policy,
      original_ops_policy
      |> Keyword.put(:default_policies, %{
        {"tenant-ok", "prod", "gateway", "gateway_runtime"} => %{
          "acl" => %{
            "main" => %{"read" => ["global."], "write" => ["global.control."]},
            "child" => %{"read" => ["agent.$agent_id."], "write" => ["agent.$agent_id."]},
            "tool" => %{"read" => ["agent.$agent_id."], "write" => ["inbox."]},
            "system" => %{"read" => [""], "write" => [""]}
          },
          "wake" => %{"must_wake" => ["agent_result"], "inbox_only" => ["telemetry"]},
          "dedup_ttl_ms" => 60_000
        },
        {"tenant-b", "prod", "gateway", "gateway_runtime"} => %{
          "acl" => %{
            "main" => %{"read" => ["global."], "write" => ["global.control."]},
            "child" => %{"read" => ["agent.$agent_id."], "write" => ["agent.$agent_id."]},
            "tool" => %{"read" => ["agent.$agent_id."], "write" => ["inbox."]},
            "system" => %{"read" => [""], "write" => [""]}
          },
          "wake" => %{"must_wake" => ["policy_changed"], "inbox_only" => ["heartbeat"]},
          "dedup_ttl_ms" => 12_345
        }
      })
    )

    OpsPolicyProvider.reset_cache()

    on_exit(fn ->
      Application.put_env(:men, OpsPolicyProvider, original_gateway)
      Application.put_env(:men, :ops_policy, original_ops_policy)
      OpsPolicyProvider.reset_cache()
    end)

    :ok
  end

  test "远端策略不可用时 fail-closed 回退 fallback，不返回旧缓存" do
    assert {:ok, first} =
             OpsPolicyProvider.get_policy(
               identity: %{tenant: "tenant-ok", env: "prod", scope: "gateway"}
             )

    assert first.policy_version == "0"

    Process.sleep(10)

    assert {:ok, second} =
             OpsPolicyProvider.get_policy(identity: %{env: "prod", scope: "gateway"})

    assert second.policy_version == "fallback"
    assert second.version == 0
  end

  test "缓存按 identity 分桶，避免跨租户命中错误策略" do
    assert {:ok, tenant_a} =
             OpsPolicyProvider.get_policy(
               identity: %{tenant: "tenant-ok", env: "prod", scope: "gateway"}
             )

    assert {:ok, tenant_b} =
             OpsPolicyProvider.get_policy(
               identity: %{tenant: "tenant-b", env: "prod", scope: "gateway"}
             )

    assert tenant_a.dedup_ttl_ms == 60_000
    assert tenant_b.dedup_ttl_ms == 12_345
    assert tenant_a.wake["must_wake"] == ["agent_result"]
    assert tenant_b.wake["must_wake"] == ["policy_changed"]
  end
end
