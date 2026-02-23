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

  test "并发重复回执幂等: 同 run_id+action_id 仅一次 stored 且事件只发送一次", %{
    opts: opts,
    topic: topic
  } do
    receipt =
      Receipt.new(%{
        run_id: "run-concurrent-1",
        action_id: "action-concurrent-1",
        status: :ok,
        code: "OK",
        message: "done",
        data: %{x: 1},
        retryable: false,
        ts: System.system_time(:millisecond)
      })

    results =
      1..20
      |> Task.async_stream(
        fn _ ->
          Receipt.record(receipt,
            session_key: "s1",
            repl_store_opts: opts,
            event_topic: topic
          )
        end,
        max_concurrency: 20,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    stored_count = Enum.count(results, &(&1 == {:ok, :stored}))
    duplicate_count = Enum.count(results, &(&1 == {:ok, :duplicate}))

    assert stored_count == 1
    assert duplicate_count == 19
    assert_receive {:gateway_event, %{type: "action_receipt", action_id: "action-concurrent-1"}}
    refute_receive {:gateway_event, %{type: "action_receipt", action_id: "action-concurrent-1"}}
  end

  test "safe_new 对缺失 run_id/action_id 返回错误" do
    assert {:error, {:invalid_required_field, :run_id}} =
             Receipt.safe_new(%{action_id: "a-1"})

    assert {:error, {:invalid_required_field, :action_id}} =
             Receipt.safe_new(%{run_id: "r-1"})
  end
end
