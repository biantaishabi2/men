defmodule Men.Gateway.ReplStoreTest do
  use ExUnit.Case, async: false

  alias Men.Gateway.EventEnvelope
  alias Men.Gateway.ReplStore

  @policy %{
    acl: %{
      "system" => %{"read" => [""], "write" => [""]},
      "main" => %{"read" => ["global."], "write" => ["global.control."]},
      "child" => %{
        "read" => ["agent.$agent_id.", "inbox."],
        "write" => ["agent.$agent_id.", "inbox."]
      },
      "tool" => %{"read" => ["agent.$agent_id."], "write" => ["inbox."]}
    },
    dedup_ttl_ms: 20,
    policy_version: "test-v1"
  }

  setup do
    opts = [
      state_table: :"repl_store_state_#{System.unique_integer([:positive, :monotonic])}",
      dedup_table: :"repl_store_dedup_#{System.unique_integer([:positive, :monotonic])}",
      inbox_table: :"repl_store_inbox_#{System.unique_integer([:positive, :monotonic])}",
      scope_table: :"repl_store_scope_#{System.unique_integer([:positive, :monotonic])}"
    ]

    ReplStore.reset(opts)
    %{opts: opts}
  end

  test "去重命中: 第二次相同 source/session/event_id 返回 duplicate", %{opts: opts} do
    envelope = envelope!("e1", 1)

    assert {:ok, %{status: :stored, duplicate: false}} =
             ReplStore.put_inbox(envelope, @policy, opts)

    assert {:ok, %{status: :duplicate, duplicate: true}} =
             ReplStore.put_inbox(envelope, @policy, opts)
  end

  test "TTL 过期后允许再次处理相同 event_id", %{opts: opts} do
    envelope = envelope!("e_ttl", 1)

    assert {:ok, %{status: :stored}} = ReplStore.put_inbox(envelope, @policy, opts)
    Process.sleep(30)

    assert {:ok, %{status: status, duplicate: false}} =
             ReplStore.put_inbox(envelope, @policy, opts)

    assert status in [:stored, :idempotent]
  end

  test "version newer/equal/older 三分支", %{opts: opts} do
    assert {:ok, %{status: :stored}} = ReplStore.put_inbox(envelope!("e2", 2), @policy, opts)
    assert {:ok, %{status: :stored}} = ReplStore.put_inbox(envelope!("e3", 3), @policy, opts)

    assert {:ok, %{status: :idempotent}} =
             ReplStore.put_inbox(envelope!("e3-eq", 3), @policy, opts)

    assert {:ok, %{status: :older_drop}} =
             ReplStore.put_inbox(envelope!("e2-old", 2), @policy, opts)

    dedup_key = {"agent.agent_a", "s1", "e2-old"}
    refute :ets.member(opts[:inbox_table], dedup_key)
  end

  test "put/get/list/query 走 ACL 并支持查询", %{opts: opts} do
    actor = %{role: :child, agent_id: "agent_a", session_key: "s1"}

    assert {:ok, :stored} =
             ReplStore.put(
               actor,
               "agent.agent_a.data.x",
               %{v: 1},
               Keyword.merge(opts, policy: @policy, version: 1)
             )

    assert {:ok, row} =
             ReplStore.get(actor, "agent.agent_a.data.x", Keyword.merge(opts, policy: @policy))

    assert row.value == %{v: 1}

    assert {:ok, listed} =
             ReplStore.list(actor, "agent.agent_a.", Keyword.merge(opts, policy: @policy))

    assert length(listed) == 1

    assert {:ok, queried} =
             ReplStore.query(
               actor,
               fn item -> item.version == 1 end,
               Keyword.merge(opts, policy: @policy)
             )

    assert length(queried) == 1
  end

  defp envelope!(event_id, version) do
    {:ok, envelope} =
      EventEnvelope.normalize(%{
        type: "agent_result",
        source: "agent.agent_a",
        session_key: "s1",
        event_id: event_id,
        version: version,
        ets_keys: ["agent.agent_a.data.result.task_1"],
        payload: %{result: "ok"}
      })

    envelope
  end
end
