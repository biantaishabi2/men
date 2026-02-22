defmodule Men.Gateway.SessionCoordinatorTest do
  use ExUnit.Case, async: false

  alias Men.Gateway.DispatchServer
  alias Men.Gateway.SessionCoordinator

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      if pid = Application.get_env(:men, :session_coordinator_test_pid) do
        send(pid, {:bridge_context, prompt, context})
      end

      {:ok, %{text: "ok:" <> prompt, meta: %{source: :mock}}}
    end
  end

  defmodule MockEgress do
    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(_target, _message), do: :ok
  end

  setup do
    Application.put_env(:men, :session_coordinator_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:men, :session_coordinator_test_pid)
    end)

    :ok
  end

  defp start_coordinator(opts \\ []) do
    name = {:global, {__MODULE__, self(), make_ref()}}

    server =
      start_supervised!(
        {SessionCoordinator,
         Keyword.merge(
           [
             name: name,
             ttl_ms: 300_000,
             gc_interval_ms: 60_000,
             max_entries: 10_000,
             invalidation_codes: [:runtime_session_not_found]
           ],
           opts
         )}
      )

    {name, server}
  end

  test "同 key 连续调用复用同一 runtime_session_id" do
    {name, _pid} = start_coordinator()
    counter = :atomics.new(1, [])

    create_fun = fn ->
      id = :atomics.add_get(counter, 1, 1)
      "runtime-" <> Integer.to_string(id)
    end

    assert {:ok, runtime_session_id_1} = SessionCoordinator.get_or_create(name, "session-A", create_fun)
    assert {:ok, runtime_session_id_2} = SessionCoordinator.get_or_create(name, "session-A", create_fun)
    assert runtime_session_id_1 == runtime_session_id_2
    assert :atomics.get(counter, 1) == 1
  end

  test "不同 key 并发调用互相隔离" do
    {name, _pid} = start_coordinator()

    tasks =
      for key <- ["session-A", "session-B", "session-C"] do
        Task.async(fn -> SessionCoordinator.get_or_create(name, key, fn -> "runtime-" <> key end) end)
      end

    results = Enum.map(tasks, &Task.await(&1, 2_000))
    assert Enum.sort(results) == Enum.sort([{:ok, "runtime-session-A"}, {:ok, "runtime-session-B"}, {:ok, "runtime-session-C"}])
  end

  test "TTL 超时后重建 runtime_session_id" do
    {name, _pid} = start_coordinator(ttl_ms: 30, gc_interval_ms: 10_000)
    counter = :atomics.new(1, [])

    create_fun = fn ->
      id = :atomics.add_get(counter, 1, 1)
      "runtime-" <> Integer.to_string(id)
    end

    assert {:ok, "runtime-1"} = SessionCoordinator.get_or_create(name, "session-A", create_fun)
    Process.sleep(40)
    assert {:ok, "runtime-2"} = SessionCoordinator.get_or_create(name, "session-A", create_fun)
  end

  test "GC 定时清理过期映射" do
    {name, pid} = start_coordinator(ttl_ms: 30, gc_interval_ms: 10_000)
    counter = :atomics.new(1, [])

    create_fun = fn ->
      id = :atomics.add_get(counter, 1, 1)
      "runtime-" <> Integer.to_string(id)
    end

    assert {:ok, "runtime-1"} = SessionCoordinator.get_or_create(name, "session-A", create_fun)
    Process.sleep(40)

    send(pid, :gc)
    Process.sleep(20)

    assert :not_found =
             SessionCoordinator.invalidate_by_runtime_session_id(name, %{
               runtime_session_id: "runtime-1",
               code: :runtime_session_not_found
             })

    assert {:ok, "runtime-2"} = SessionCoordinator.get_or_create(name, "session-A", create_fun)
  end

  test "显式失效剔除后下次重新创建" do
    {name, _pid} = start_coordinator()
    counter = :atomics.new(1, [])

    create_fun = fn ->
      id = :atomics.add_get(counter, 1, 1)
      "runtime-" <> Integer.to_string(id)
    end

    assert {:ok, "runtime-1"} = SessionCoordinator.get_or_create(name, "session-A", create_fun)

    assert :ok =
             SessionCoordinator.invalidate_by_session_key(name, %{
               session_key: "session-A",
               code: :runtime_session_not_found
             })

    assert {:ok, "runtime-2"} = SessionCoordinator.get_or_create(name, "session-A", create_fun)
  end

  test "按 runtime_session_id 失效后下次重新创建" do
    {name, _pid} = start_coordinator()
    counter = :atomics.new(1, [])

    create_fun = fn ->
      id = :atomics.add_get(counter, 1, 1)
      "runtime-" <> Integer.to_string(id)
    end

    assert {:ok, "runtime-1"} = SessionCoordinator.get_or_create(name, "session-A", create_fun)

    assert :ok =
             SessionCoordinator.invalidate_by_runtime_session_id(name, %{
               runtime_session_id: "runtime-1",
               code: :runtime_session_not_found
             })

    assert {:ok, "runtime-2"} = SessionCoordinator.get_or_create(name, "session-A", create_fun)
  end

  test "非白名单错误码返回 ignored 且不删除映射" do
    {name, _pid} = start_coordinator()

    assert {:ok, "runtime-A"} = SessionCoordinator.get_or_create(name, "session-A", fn -> "runtime-A" end)

    assert :ignored =
             SessionCoordinator.invalidate_by_runtime_session_id(name, %{
               runtime_session_id: "runtime-A",
               code: :some_other_error
             })

    assert {:ok, "runtime-A"} = SessionCoordinator.get_or_create(name, "session-A", fn -> "runtime-A-new" end)
  end

  test "达到容量后按 LRU 淘汰最旧 last_access_at" do
    {name, _pid} = start_coordinator(max_entries: 2)

    assert {:ok, "runtime-A"} = SessionCoordinator.get_or_create(name, "session-A", fn -> "runtime-A" end)
    Process.sleep(2)
    assert {:ok, "runtime-B"} = SessionCoordinator.get_or_create(name, "session-B", fn -> "runtime-B" end)
    Process.sleep(2)
    assert {:ok, "runtime-A"} = SessionCoordinator.get_or_create(name, "session-A", fn -> "runtime-A-new" end)
    Process.sleep(2)
    assert {:ok, "runtime-C"} = SessionCoordinator.get_or_create(name, "session-C", fn -> "runtime-C" end)

    assert {:ok, "runtime-A"} = SessionCoordinator.get_or_create(name, "session-A", fn -> "runtime-A-new-2" end)
    assert {:ok, "runtime-B-new"} = SessionCoordinator.get_or_create(name, "session-B", fn -> "runtime-B-new" end)
  end

  test "同 key 并发安全：create_fun 只执行一次" do
    {name, _pid} = start_coordinator()
    counter = :atomics.new(1, [])

    create_fun = fn ->
      id = :atomics.add_get(counter, 1, 1)
      Process.sleep(10)
      "runtime-" <> Integer.to_string(id)
    end

    tasks =
      for _ <- 1..10 do
        Task.async(fn -> SessionCoordinator.get_or_create(name, "session-race", create_fun) end)
      end

    results = Enum.map(tasks, &Task.await(&1, 2_000))
    assert Enum.uniq(results) == [{:ok, "runtime-1"}]
    assert :atomics.get(counter, 1) == 1
  end

  test "create_fun 返回非法 runtime_session_id 时返回错误且不写入映射" do
    {name, _pid} = start_coordinator()

    assert {:error, {:invalid_runtime_session_id, nil}} =
             SessionCoordinator.get_or_create(name, "session-invalid", fn -> nil end)

    assert {:ok, "runtime-valid"} =
             SessionCoordinator.get_or_create(name, "session-invalid", fn -> "runtime-valid" end)
  end

  test "invalidate 传入非法 reason 时返回 ignored 且不删除映射" do
    {name, _pid} = start_coordinator()

    assert {:ok, "runtime-A"} = SessionCoordinator.get_or_create(name, "session-A", fn -> "runtime-A" end)
    assert {:ok, "runtime-B"} = SessionCoordinator.get_or_create(name, "session-B", fn -> "runtime-B" end)

    assert :ignored = SessionCoordinator.invalidate_by_runtime_session_id(name, %{code: :runtime_session_not_found})
    assert :ignored = SessionCoordinator.invalidate_by_session_key(name, {:bad_reason})

    assert {:ok, "runtime-A"} = SessionCoordinator.get_or_create(name, "session-A", fn -> "runtime-A-new" end)
    assert {:ok, "runtime-B"} = SessionCoordinator.get_or_create(name, "session-B", fn -> "runtime-B-new" end)
  end

  test "coordinator 关闭时 dispatch 回退到一次一会话策略" do
    server =
      start_supervised!(
        {DispatchServer,
         name: {:global, {__MODULE__, :dispatch, self(), make_ref()}},
         bridge_adapter: MockBridge,
         egress_adapter: MockEgress,
         session_coordinator_enabled: false}
      )

    event = %{
      request_id: "req-disabled-1",
      payload: "hello",
      channel: "feishu",
      user_id: "u-disabled"
    }

    assert {:ok, result} = DispatchServer.dispatch(server, event)
    assert result.session_key == "feishu:u-disabled"
    assert_receive {:bridge_context, "hello", %{session_key: "feishu:u-disabled"}}
  end
end
