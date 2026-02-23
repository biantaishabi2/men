defmodule Men.Channels.Ingress.QiweiIdempotencyTest do
  use ExUnit.Case, async: false

  alias Men.Channels.Ingress.QiweiIdempotency

  defmodule BrokenBackend do
    @behaviour Men.Channels.Ingress.QiweiIdempotency.Backend

    @impl true
    def get(_key), do: {:error, :backend_down}

    @impl true
    def put_if_absent(_key, _value, _ttl_seconds), do: {:error, :backend_down}

    @impl true
    def put(_key, _value, _ttl_seconds), do: {:error, :backend_down}
  end

  defmodule ConcurrentBackend do
    @behaviour Men.Channels.Ingress.QiweiIdempotency.Backend

    def start_link do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{} end)
    end

    @impl true
    def get(key) do
      {:ok, Agent.get(__MODULE__, &Map.get(&1, key))}
    end

    @impl true
    def put_if_absent(key, value, _ttl_seconds) do
      Agent.get_and_update(__MODULE__, fn state ->
        if Map.has_key?(state, key) do
          {{:error, :exists}, state}
        else
          {:ok, Map.put(state, key, value)}
        end
      end)
    end

    @impl true
    def put(key, value, _ttl_seconds) do
      Agent.update(__MODULE__, &Map.put(&1, key, value))
      :ok
    end
  end

  setup_all do
    {:ok, _pid} = ConcurrentBackend.start_link()
    :ok
  end

  setup do
    ConcurrentBackend.reset()
    :ok
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

  test "并发重复请求仅执行一次 side effect" do
    event = %{
      payload: %{
        corp_id: "wwcorp",
        agent_id: 1_000_001,
        msg_id: "mid-concurrent-#{System.unique_integer([:positive])}"
      }
    }

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    callback = fn ->
      Agent.update(counter, &(&1 + 1))
      Process.sleep(80)
      %{type: :xml, body: "<xml>first</xml>"}
    end

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          QiweiIdempotency.with_idempotency(event, callback, backend: ConcurrentBackend)
        end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 == %{type: :xml, body: "<xml>first</xml>"}))
    assert Agent.get(counter, & &1) == 1
  end
end
