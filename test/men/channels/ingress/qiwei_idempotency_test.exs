defmodule Men.Channels.Ingress.QiweiIdempotencyTest do
  use ExUnit.Case, async: false

  alias Men.Channels.Ingress.QiweiIdempotency

  setup do
    original = Application.get_env(:men, :qiwei, [])
    Application.put_env(:men, :qiwei, idempotency_ttl_seconds: 1)

    on_exit(fn ->
      Application.put_env(:men, :qiwei, original)
    end)

    :ok
  end

  test "key 生成：普通消息使用 corp+agent+msg_id" do
    event = %{
      request_id: "req-1",
      payload: %{corp_id: "corpA", agent_id: "1001", msg_type: "text", msg_id: "msg-1"}
    }

    assert QiweiIdempotency.key(event) == "qiwei:corpA:1001:msg-1"
  end

  test "key 生成：事件消息使用 from_user+create_time+event+event_key" do
    event = %{
      payload: %{
        corp_id: "corpB",
        agent_id: "1002",
        msg_type: "event",
        from_user: "u1",
        create_time: 1_700_000_000,
        event: "enter_agent",
        event_key: "k1"
      }
    }

    assert QiweiIdempotency.key(event) == "qiwei:corpB:1002:u1:1700000000:enter_agent:k1"
  end

  test "重复投递命中幂等：第二次不重复执行 side effect 且返回一致结果" do
    event = %{
      request_id: "req-repeat-1",
      payload: %{corp_id: "corpC", agent_id: "1003", msg_type: "text", msg_id: "msg-repeat"}
    }

    counter = :erlang.make_ref()
    Process.put(counter, 0)

    producer = fn ->
      Process.put(counter, Process.get(counter, 0) + 1)
      {:xml, "<xml>ok</xml>"}
    end

    assert {:fresh, {:xml, "<xml>ok</xml>"}} = QiweiIdempotency.fetch_or_store(event, producer)

    assert {:duplicate, {:xml, "<xml>ok</xml>"}} =
             QiweiIdempotency.fetch_or_store(event, producer)

    assert Process.get(counter) == 1
  end

  test "TTL 过期后可再次执行 producer" do
    event = %{
      request_id: "req-expire-1",
      payload: %{corp_id: "corpD", agent_id: "1004", msg_type: "text", msg_id: "msg-expire"}
    }

    counter = :erlang.make_ref()
    Process.put(counter, 0)

    producer = fn ->
      Process.put(counter, Process.get(counter, 0) + 1)
      {:success}
    end

    assert {:fresh, {:success}} = QiweiIdempotency.fetch_or_store(event, producer, ttl_seconds: 1)

    assert {:duplicate, {:success}} =
             QiweiIdempotency.fetch_or_store(event, producer, ttl_seconds: 1)

    Process.sleep(1_100)

    assert {:fresh, {:success}} = QiweiIdempotency.fetch_or_store(event, producer, ttl_seconds: 1)
    assert Process.get(counter) == 2
  end

  test "并发长耗时：同 key 只执行一次 side effect" do
    event = %{
      request_id: "req-concurrent-1",
      payload: %{corp_id: "corpE", agent_id: "1005", msg_type: "text", msg_id: "msg-concurrent"}
    }

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    producer = fn ->
      Agent.update(counter, &(&1 + 1))
      Process.sleep(1_200)
      {:xml, "<xml>concurrent</xml>"}
    end

    results =
      1..2
      |> Task.async_stream(
        fn _ ->
          QiweiIdempotency.fetch_or_store(event, producer,
            ttl_seconds: 120,
            pending_wait_timeout_ms: 3_000
          )
        end,
        timeout: 5_000,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:fresh, _}, &1)) == 1
    assert Enum.count(results, &match?({:duplicate, _}, &1)) == 1
    assert Enum.all?(results, &match?({_, {:xml, "<xml>concurrent</xml>"}}, &1))
    assert Agent.get(counter, & &1) == 1
  end
end
