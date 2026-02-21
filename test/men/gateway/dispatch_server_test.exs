defmodule Men.Gateway.DispatchServerTest do
  use ExUnit.Case, async: false

  alias Men.Channels.Egress.Messages.{ErrorMessage, FinalMessage}
  alias Men.Gateway.DispatchServer

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      notify({:bridge_called, prompt, context})

      cond do
        prompt == "runtime_session_not_found" ->
          {:error,
           %{
             type: :failed,
             code: "runtime_session_not_found",
             message: "runtime session missing",
             details: %{source: :mock}
           }}

        prompt == "bridge_error" ->
          {:error,
           %{
             type: :failed,
             code: "BRIDGE_FAIL",
             message: "runtime bridge failed",
             details: %{source: :mock}
           }}

        prompt == "slow" ->
          Process.sleep(200)

          {:ok,
           %{
             text: "ok:" <> prompt,
             meta: %{source: :mock, echoed_run_id: context.run_id}
           }}

        true ->
          {:ok,
           %{
             text: "ok:" <> prompt,
             meta: %{source: :mock, echoed_run_id: context.run_id}
           }}
      end
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :dispatch_server_test_pid) do
        send(pid, message)
      end

      :ok
    end
  end

  defmodule MockEgress do
    import Kernel, except: [send: 2]

    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(target, message) do
      notify({:egress_called, target, message})

      case {Application.get_env(:men, :dispatch_server_test_fail_final_egress), message} do
        {reason, %Men.Channels.Egress.Messages.FinalMessage{}} when not is_nil(reason) ->
          {:error, reason}

        _ ->
          case {Application.get_env(:men, :dispatch_server_test_fail_error_egress), message} do
            {reason, %Men.Channels.Egress.Messages.ErrorMessage{}} when not is_nil(reason) ->
              {:error, reason}

            _ ->
              :ok
          end
      end
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :dispatch_server_test_pid) do
        Kernel.send(pid, message)
      end

      :ok
    end
  end

  setup do
    Application.put_env(:men, :dispatch_server_test_pid, self())
    Application.delete_env(:men, :dispatch_server_test_fail_final_egress)
    Application.delete_env(:men, :dispatch_server_test_fail_error_egress)

    on_exit(fn ->
      Application.delete_env(:men, :dispatch_server_test_pid)
      Application.delete_env(:men, :dispatch_server_test_fail_final_egress)
      Application.delete_env(:men, :dispatch_server_test_fail_error_egress)
    end)

    :ok
  end

  defp start_dispatch_server(opts \\ []) do
    default_opts = [
      name: {:global, {__MODULE__, self(), make_ref()}},
      bridge_adapter: MockBridge,
      egress_adapter: MockEgress,
      session_coordinator_enabled: false
    ]

    start_supervised!(
      {DispatchServer,
       Keyword.merge(default_opts, opts)}
    )
  end

  defp start_transient_coordinator(mode) do
    name = {:global, {__MODULE__, :coordinator, self(), make_ref()}}
    pid = spawn(fn -> transient_coordinator_loop(mode) end)
    :yes = :global.register_name(name, pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :global.unregister_name(name)
    end)

    name
  end

  defp transient_coordinator_loop(:crash_on_get_or_create) do
    receive do
      {:"$gen_call", _from, {:get_or_create, _session_key, _create_fun}} ->
        exit(:coordinator_restarting)
    end
  end

  defp transient_coordinator_loop(:crash_on_invalidate) do
    receive do
      {:"$gen_call", from, {:get_or_create, _session_key, create_fun}} ->
        GenServer.reply(from, {:ok, create_fun.()})
        transient_coordinator_loop(:wait_invalidate)
    end
  end

  defp transient_coordinator_loop(:wait_invalidate) do
    receive do
      {:"$gen_call", _from, {:invalidate_by_session_key, _reason}} ->
        exit(:coordinator_restarting)
    end
  end

  test "有效 inbound event: bridge 成功并触发 final egress" do
    server = start_dispatch_server()

    event = %{
      request_id: "req-1",
      payload: "hello",
      metadata: %{source: :test},
      channel: "feishu",
      user_id: "u100"
    }

    assert {:ok, result} = DispatchServer.dispatch(server, event)
    assert result.request_id == "req-1"
    assert is_binary(result.run_id)
    assert result.session_key == "feishu:u100"

    assert_receive {:bridge_called, "hello",
                    %{request_id: "req-1", run_id: run_id, session_key: "feishu:u100"}}

    assert run_id == result.run_id

    assert_receive {:egress_called, "feishu:u100", %FinalMessage{} = message}
    assert message.content == "ok:hello"
    assert message.metadata.request_id == "req-1"
    assert message.metadata.run_id == result.run_id
  end

  test "bridge error: 触发 error egress 并返回 error_result" do
    server = start_dispatch_server()

    event = %{
      request_id: "req-2",
      payload: "bridge_error",
      channel: "feishu",
      user_id: "u200"
    }

    assert {:error, error_result} = DispatchServer.dispatch(server, event)
    assert error_result.code == "BRIDGE_FAIL"
    assert error_result.reason == "runtime bridge failed"
    assert error_result.session_key == "feishu:u200"

    assert_receive {:egress_called, "feishu:u200", %ErrorMessage{} = message}
    assert message.code == "BRIDGE_FAIL"
    assert message.reason == "runtime bridge failed"
  end

  test "error egress 失败: 调用方可感知 EGRESS_ERROR" do
    Application.put_env(:men, :dispatch_server_test_fail_error_egress, :error_channel_unavailable)

    server = start_dispatch_server()

    event = %{
      request_id: "req-2b",
      payload: "bridge_error",
      channel: "feishu",
      user_id: "u201"
    }

    assert {:error, error_result} = DispatchServer.dispatch(server, event)
    assert error_result.code == "EGRESS_ERROR"
    assert error_result.reason == "egress send failed"

    assert_receive {:egress_called, "feishu:u201", %ErrorMessage{} = message}
    assert message.code == "BRIDGE_FAIL"
  end

  test "重复 run_id: 返回 duplicate 且不重复 egress" do
    server = start_dispatch_server()

    event = %{
      request_id: "req-3",
      run_id: "fixed-run-id",
      payload: "hello",
      channel: "feishu",
      user_id: "u300"
    }

    assert {:ok, _result} = DispatchServer.dispatch(server, event)
    assert_receive {:egress_called, "feishu:u300", %FinalMessage{}}

    assert {:ok, :duplicate} = DispatchServer.dispatch(server, event)
    refute_receive {:egress_called, "feishu:u300", %FinalMessage{}}
    refute_receive {:egress_called, "feishu:u300", %ErrorMessage{}}
  end

  test "egress 失败返回 EGRESS_ERROR 时不标记 processed，可同 run_id 重试" do
    Application.put_env(:men, :dispatch_server_test_fail_final_egress, :downstream_unavailable)

    server = start_dispatch_server()

    event = %{
      request_id: "req-3b",
      run_id: "retryable-run-id",
      payload: "hello",
      channel: "feishu",
      user_id: "u301"
    }

    assert {:error, error_result} = DispatchServer.dispatch(server, event)
    assert error_result.code == "EGRESS_ERROR"

    Application.delete_env(:men, :dispatch_server_test_fail_final_egress)

    assert {:ok, result} = DispatchServer.dispatch(server, event)
    assert result.run_id == "retryable-run-id"
    assert {:ok, :duplicate} = DispatchServer.dispatch(server, event)
  end

  test "同 session 连续消息: session_key 一致且可连续处理" do
    server = start_dispatch_server()

    event1 = %{
      request_id: "req-4-1",
      payload: "turn-1",
      channel: "feishu",
      user_id: "u400",
      thread_id: "t01"
    }

    event2 = %{
      request_id: "req-4-2",
      payload: "turn-2",
      channel: "feishu",
      user_id: "u400",
      thread_id: "t01"
    }

    assert {:ok, result1} = DispatchServer.dispatch(server, event1)
    assert {:ok, result2} = DispatchServer.dispatch(server, event2)

    assert result1.session_key == "feishu:u400:t:t01"
    assert result2.session_key == "feishu:u400:t:t01"

    assert_receive {:bridge_called, "turn-1", %{session_key: "feishu:u400:t:t01"}}
    assert_receive {:bridge_called, "turn-2", %{session_key: "feishu:u400:t:t01"}}
  end

  test "同 run_id 并发提交: 只处理一次，其余命中 duplicate" do
    server = start_dispatch_server()

    event = %{
      request_id: "req-5",
      run_id: "concurrent-run-id",
      payload: "hello",
      channel: "feishu",
      user_id: "u500"
    }

    tasks =
      for _ <- 1..2 do
        Task.async(fn -> DispatchServer.dispatch(server, event) end)
      end

    results = Enum.map(tasks, &Task.await(&1, 2_000))

    assert Enum.count(results, &match?({:ok, :duplicate}, &1)) == 1

    assert Enum.count(results, fn
             {:ok, %{run_id: "concurrent-run-id"}} -> true
             _ -> false
           end) == 1

    assert_receive {:egress_called, "feishu:u500", %FinalMessage{}}
    refute_receive {:egress_called, "feishu:u500", %FinalMessage{}}
  end

  test "enqueue 非阻塞：HTTP/Controller 可快速 ACK，后台继续执行" do
    server = start_dispatch_server()

    event = %{
      request_id: "req-async-1",
      payload: "slow",
      channel: "feishu",
      user_id: "u-async"
    }

    started_at = System.monotonic_time(:millisecond)
    assert :ok = DispatchServer.enqueue(server, event)
    duration_ms = System.monotonic_time(:millisecond) - started_at

    assert duration_ms < 120
    assert_receive {:bridge_called, "slow", %{request_id: "req-async-1"}}, 1_000
    assert_receive {:egress_called, "feishu:u-async", %FinalMessage{} = message}, 1_000
    assert message.content == "ok:slow"
  end

  test "关键边界输入: 非法 request_id / metadata 非 map / 路由字段不足" do
    server = start_dispatch_server()

    invalid_events = [
      %{request_id: "", payload: "hello", channel: "feishu", user_id: "u600"},
      %{request_id: 123, payload: "hello", channel: "feishu", user_id: "u600"},
      %{
        request_id: "req-6-3",
        payload: "hello",
        metadata: "bad",
        channel: "feishu",
        user_id: "u600"
      },
      %{request_id: "req-6-4", payload: "hello"}
    ]

    for event <- invalid_events do
      assert {:error, error_result} = DispatchServer.dispatch(server, event)
      assert error_result.code == "INVALID_EVENT"
      assert error_result.reason == "invalid inbound event"
    end

    assert_receive {:egress_called, _, %ErrorMessage{}}
    assert_receive {:egress_called, _, %ErrorMessage{}}
    assert_receive {:egress_called, _, %ErrorMessage{}}
    assert_receive {:egress_called, _, %ErrorMessage{}}
    refute_receive {:bridge_called, _, _}
  end

  test "session coordinator 在 get_or_create 调用窗口退出时回退到原始 session_key" do
    coordinator_name = start_transient_coordinator(:crash_on_get_or_create)

    server =
      start_dispatch_server(
        session_coordinator_enabled: true,
        session_coordinator_name: coordinator_name
      )

    event = %{
      request_id: "req-coord-race-1",
      payload: "hello",
      channel: "feishu",
      user_id: "u-race-1"
    }

    assert {:ok, result} = DispatchServer.dispatch(server, event)
    assert result.session_key == "feishu:u-race-1"
    assert_receive {:bridge_called, "hello", %{session_key: "feishu:u-race-1"}}
  end

  test "session coordinator 在 invalidate 调用窗口退出时不影响错误返回" do
    coordinator_name = start_transient_coordinator(:crash_on_invalidate)

    server =
      start_dispatch_server(
        session_coordinator_enabled: true,
        session_coordinator_name: coordinator_name
      )

    event = %{
      request_id: "req-coord-race-2",
      payload: "runtime_session_not_found",
      channel: "feishu",
      user_id: "u-race-2"
    }

    assert {:error, error_result} = DispatchServer.dispatch(server, event)
    assert error_result.code == "runtime_session_not_found"
    assert error_result.reason == "runtime session missing"
    assert_receive {:egress_called, "feishu:u-race-2", %ErrorMessage{code: "runtime_session_not_found"}}
  end
end
