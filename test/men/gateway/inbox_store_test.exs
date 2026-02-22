defmodule Men.Gateway.InboxStoreTest do
  use ExUnit.Case, async: false

  alias Men.Gateway.EventEnvelope
  alias Men.Gateway.InboxStore

  setup do
    opts = [
      event_table: :"inbox_store_test_event_#{System.unique_integer([:positive, :monotonic])}",
      scope_table: :"inbox_store_test_scope_#{System.unique_integer([:positive, :monotonic])}"
    ]

    InboxStore.reset(opts)
    %{opts: opts}
  end

  test "event_id 去重：重复事件返回 duplicate", %{opts: opts} do
    envelope = envelope!("E3", 3, ["scope", "1"])

    assert {:ok, _} = InboxStore.put(envelope, opts)
    assert {:duplicate, _} = InboxStore.put(envelope, opts)
  end

  test "版本推进：同 ets_keys 仅接受更高版本", %{opts: opts} do
    latest = envelope!("E8", 8, ["scope", "2"])
    stale = envelope!("E5", 5, ["scope", "2"])

    assert {:ok, _} = InboxStore.put(latest, opts)
    assert {:stale, _} = InboxStore.put(stale, opts)

    assert {:ok, snapshot} = InboxStore.latest_by_ets_keys(["scope", "2"], opts)
    assert snapshot.event_id == "E8"
    assert snapshot.version == 8
  end

  test "并发写入一致性：最终快照保持最高版本", %{opts: opts} do
    envelopes =
      for version <- 1..20 do
        envelope!("E#{version}", version, ["scope", "3"])
      end

    tasks =
      Enum.map(envelopes, fn envelope ->
        Task.async(fn -> InboxStore.put(envelope, opts) end)
      end)

    results = Enum.map(tasks, &Task.await(&1, 2_000))
    assert Enum.any?(results, &match?({:ok, _}, &1))

    assert {:ok, snapshot} = InboxStore.latest_by_ets_keys(["scope", "3"], opts)
    assert snapshot.version == 20
    assert snapshot.event_id == "E20"
  end

  defp envelope!(event_id, version, ets_keys) do
    {:ok, envelope} =
      EventEnvelope.normalize(%{
        type: "agent_result",
        source: "agent",
        target: "control",
        event_id: event_id,
        version: version,
        wake: true,
        inbox_only: false,
        ets_keys: ets_keys
      })

    envelope
  end
end
