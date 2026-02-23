defmodule Men.Gateway.ReceiptTest do
  use ExUnit.Case, async: false

  alias Men.Gateway.EventBus
  alias Men.Gateway.Receipt
  alias Men.Gateway.ReplStore

  setup do
    opts = [
      state_table: :"receipt_state_#{System.unique_integer([:positive, :monotonic])}",
      dedup_table: :"receipt_dedup_#{System.unique_integer([:positive, :monotonic])}",
      inbox_table: :"receipt_inbox_#{System.unique_integer([:positive, :monotonic])}",
      scope_table: :"receipt_scope_#{System.unique_integer([:positive, :monotonic])}"
    ]

    ReplStore.reset(opts)

    topic = "receipt_test_#{System.unique_integer([:positive, :monotonic])}"
    :ok = EventBus.subscribe(topic)

    %{opts: opts, topic: topic}
  end

  test "先写状态再发事件，重复回执幂等", %{opts: opts, topic: topic} do
    receipt =
      Receipt.new(%{
        run_id: "run-1",
        action_id: "action-1",
        status: :ok,
        code: "OK",
        message: "done",
        data: %{x: 1},
        retryable: false,
        ts: System.system_time(:millisecond)
      })

    assert {:ok, :stored} =
             Receipt.record(receipt,
               session_key: "s1",
               repl_store_opts: opts,
               event_topic: topic
             )

    assert_receive {:gateway_event, %{type: "action_receipt", action_id: "action-1"}}

    assert {:ok, :duplicate} =
             Receipt.record(receipt,
               session_key: "s1",
               repl_store_opts: opts,
               event_topic: topic
             )

    refute_receive {:gateway_event, %{type: "action_receipt", action_id: "action-1"}}
  end
end
