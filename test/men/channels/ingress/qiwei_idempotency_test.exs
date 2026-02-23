defmodule Men.Channels.Ingress.QiweiIdempotencyTest do
  use ExUnit.Case, async: false

  alias Men.Channels.Ingress.QiweiIdempotency

  defmodule BrokenBackend do
    @behaviour Men.Channels.Ingress.QiweiIdempotency.Backend

    @impl true
    def get(_key), do: {:error, :backend_down}

    @impl true
    def put_if_absent(_key, _value, _ttl_seconds), do: {:error, :backend_down}
  end

  test "消息 key 生成使用 corp_id+agent_id+msg_id" do
    event = %{
      payload: %{
        corp_id: "wwcorp",
        agent_id: 1_000_001,
        msg_id: "mid-100"
      }
    }

    assert QiweiIdempotency.key(event) == "qiwei:wwcorp:1000001:mid-100"
  end

  test "事件 key 生成使用 from_user+create_time+event+event_key" do
    event = %{
      payload: %{
        corp_id: "wwcorp",
        agent_id: 1_000_001,
        from_user: "u100",
        create_time: 1_700_000_000,
        event: "enter_agent",
        event_key: "menu_1"
      }
    }

    assert QiweiIdempotency.key(event) ==
             "qiwei:wwcorp:1000001:u100:1700000000:enter_agent:menu_1"
  end

  test "首次执行会缓存，重复请求返回首次一致响应" do
    event = %{
      payload: %{
        corp_id: "wwcorp",
        agent_id: 1_000_001,
        msg_id: "mid-repeat-#{System.unique_integer([:positive])}"
      }
    }

    first =
      QiweiIdempotency.with_idempotency(event, fn ->
        %{type: :xml, body: "<xml>first</xml>"}
      end)

    second =
      QiweiIdempotency.with_idempotency(event, fn ->
        %{type: :xml, body: "<xml>second</xml>"}
      end)

    assert first == %{type: :xml, body: "<xml>first</xml>"}
    assert second == first
  end

  test "TTL 过期后允许再次执行" do
    event = %{
      payload: %{
        corp_id: "wwcorp",
        agent_id: 1_000_001,
        msg_id: "mid-ttl-#{System.unique_integer([:positive])}"
      }
    }

    first = QiweiIdempotency.with_idempotency(event, fn -> %{type: :success} end, ttl_seconds: 1)
    Process.sleep(1_100)

    second =
      QiweiIdempotency.with_idempotency(
        event,
        fn -> %{type: :xml, body: "<xml>after-ttl</xml>"} end,
        ttl_seconds: 1
      )

    assert first == %{type: :success}
    assert second == %{type: :xml, body: "<xml>after-ttl</xml>"}
  end

  test "backend 不可用时 fail-open" do
    event = %{
      payload: %{
        corp_id: "wwcorp",
        agent_id: 1_000_001,
        msg_id: "mid-fail-open"
      }
    }

    response =
      QiweiIdempotency.with_idempotency(
        event,
        fn -> %{type: :success} end,
        backend: BrokenBackend
      )

    assert response == %{type: :success}
  end
end
