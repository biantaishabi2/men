defmodule Men.Gateway.DispatchServerTest do
  use ExUnit.Case, async: false

  alias Men.Channels.Egress.Messages.{ErrorMessage, EventMessage, FinalMessage}
  alias Men.Gateway.DispatchServer
  alias Men.Gateway.SessionCoordinator

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      notify({:bridge_called, prompt, context})

      cond do
        prompt == "session_not_found_once" ->
          attempt = Process.get({:bridge_attempt, context.run_id}, 0) + 1
          Process.put({:bridge_attempt, context.run_id}, attempt)

          if attempt == 1 do
            {:error,
             %{
               type: :failed,
               code: "session_not_found",
               message: "runtime session missing",
               details: %{source: :mock}
             }}
          else
            ok_payload(prompt, context)
          end

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
          ok_payload(prompt, context)

        prompt == "stream_delta" ->
          emit_delta(context, "partial:stream_delta")
          ok_payload(prompt, context)

        true ->
          ok_payload(prompt, context)
      end
    end

    defp ok_payload(prompt, context) do
      {:ok,
       %{
         text: "ok:" <> prompt,
         meta: %{source: :mock, echoed_run_id: context.run_id}
       }}
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :dispatch_server_test_pid) do
        send(pid, message)
      end

      :ok
    end

    defp emit_delta(context, text) do
      callback = Map.get(context, :event_callback)
      if is_function(callback, 1), do: callback.(%{type: :delta, payload: %{text: text}})
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

  defp start_session_coordinator(opts \\ []) do
    name = {:global, {__MODULE__, :coordinator, self(), make_ref()}}

    start_supervised!(
      {SessionCoordinator,
       Keyword.merge(
         [
           name: name,
           ttl_ms: 300_000,
           gc_interval_ms: 60_000,
           max_entries: 10_000,
           invalidation_codes: [:runtime_session_not_found, :session_not_found]
         ],
         opts
       )}
    )

    name
  end

  defp start_transient_coordinator(mode) do
    name = {:global, {__MODULE__, :transient_coordinator, self(), make_ref()}}
    pid = spawn(fn -> transient_coordinator_loop(mode) end)
    :yes = :global.register_name(name, pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :global.unregister_name(name)
    end)

    name
  end

  defp transient_coordinator_loop(:crash_on_get_or_create_session) do
    receive do
      {:"$gen_call", _from, {:get_or_create_session, _session_key}} ->
        exit(:coordinator_restarting)
    end
  end

  defp transient_coordinator_loop(:crash_on_rebuild_session) do
    receive do
      {:"$gen_call", from, {:get_or_create_session, _session_key}} ->
        GenServer.reply(from, {:ok, "runtime-session-transient"})
        transient_coordinator_loop(:wait_rebuild)
    end
  end

  defp transient_coordinator_loop(:wait_rebuild) do
    receive do
      {:"$gen_call", _from, {:rebuild_session, _session_key}} ->
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

  test "同 key 连续消息复用 runtime_session_id" do
    coordinator_name = start_session_coordinator()

    server =
      start_dispatch_server(
        session_coordinator_enabled: true,
        session_coordinator_name: coordinator_name
      )

    event1 = %{
      request_id: "req-reuse-1",
      payload: "turn-1",
      channel: "feishu",
      user_id: "u400",
      thread_id: "t01"
    }

    event2 = %{
      request_id: "req-reuse-2",
      payload: "turn-2",
      channel: "feishu",
      user_id: "u400",
      thread_id: "t01"
    }

    assert {:ok, result1} = DispatchServer.dispatch(server, event1)
    assert {:ok, result2} = DispatchServer.dispatch(server, event2)

    assert result1.session_key == "feishu:u400:t:t01"
    assert result2.session_key == "feishu:u400:t:t01"

    assert_receive {:bridge_called, "turn-1", %{session_key: runtime_session_id_1, external_session_key: "feishu:u400:t:t01"}}
    assert_receive {:bridge_called, "turn-2", %{session_key: runtime_session_id_2, external_session_key: "feishu:u400:t:t01"}}
    assert runtime_session_id_1 == runtime_session_id_2
  end

  test "session_not_found 当前语义：不重建重试，直接 error 回写" do
    coordinator_name = start_session_coordinator()

    server =
      start_dispatch_server(
        session_coordinator_enabled: true,
        session_coordinator_name: coordinator_name
      )

    event = %{
      request_id: "req-heal-1",
      run_id: "run-heal-1",
      payload: "session_not_found_once",
      channel: "feishu",
      user_id: "u-heal"
    }

    assert {:error, error_result} = DispatchServer.dispatch(server, event)
    assert error_result.run_id == "run-heal-1"
    assert error_result.code == "session_not_found"

    assert_receive {:bridge_called, "session_not_found_once", %{run_id: "run-heal-1"}}
    refute_receive {:bridge_called, "session_not_found_once", %{run_id: "run-heal-1"}}

    assert_receive {:egress_called, "feishu:u-heal", %ErrorMessage{} = message}
    assert message.code == "session_not_found"
    refute_receive {:egress_called, "feishu:u-heal", %FinalMessage{}}
  end

  test "runtime_session_not_found 不重试" do
    coordinator_name = start_session_coordinator()

    server =
      start_dispatch_server(
        session_coordinator_enabled: true,
        session_coordinator_name: coordinator_name
      )

    event = %{
      request_id: "req-no-retry-1",
      run_id: "run-no-retry-1",
      payload: "runtime_session_not_found",
      channel: "feishu",
      user_id: "u-no-retry"
    }

    assert {:error, error_result} = DispatchServer.dispatch(server, event)
    assert error_result.code == "runtime_session_not_found"
    assert_receive {:bridge_called, "runtime_session_not_found", %{run_id: "run-no-retry-1"}}
    refute_receive {:bridge_called, "runtime_session_not_found", %{run_id: "run-no-retry-1"}}

    assert_receive {:egress_called, "feishu:u-no-retry", %ErrorMessage{} = message}
    assert message.code == "runtime_session_not_found"
  end

  test "当前语义下 duplicate 命中不会重新执行 runtime" do
    server = start_dispatch_server()

    event_1 = %{
      request_id: "req-cache-1",
      run_id: "run-cache-1",
      payload: "cache-1",
      channel: "feishu",
      user_id: "u-cache"
    }

    event_2 = %{
      request_id: "req-cache-2",
      run_id: "run-cache-2",
      payload: "cache-2",
      channel: "feishu",
      user_id: "u-cache"
    }

    event_3 = %{
      request_id: "req-cache-3",
      run_id: "run-cache-3",
      payload: "cache-3",
      channel: "feishu",
      user_id: "u-cache"
    }

    assert {:ok, _} = DispatchServer.dispatch(server, event_1)
    assert_receive {:bridge_called, "cache-1", %{run_id: "run-cache-1"}}
    assert {:ok, _} = DispatchServer.dispatch(server, event_2)
    assert_receive {:bridge_called, "cache-2", %{run_id: "run-cache-2"}}
    assert {:ok, _} = DispatchServer.dispatch(server, event_3)
    assert_receive {:bridge_called, "cache-3", %{run_id: "run-cache-3"}}

    assert {:ok, :duplicate} = DispatchServer.dispatch(server, event_2)
    refute_receive {:bridge_called, "cache-2", %{run_id: "run-cache-2"}}

    assert {:ok, :duplicate} = DispatchServer.dispatch(server, event_1)
    refute_receive {:bridge_called, "cache-1", %{run_id: "run-cache-1"}}
  end

  test "run_id 幂等命中 duplicate 且不重复出站" do
    server = start_dispatch_server()

    event = %{
      request_id: "req-idempotent-1",
      run_id: "fixed-run-id",
      payload: "hello",
      channel: "feishu",
      user_id: "u300"
    }

    assert {:ok, first_result} = DispatchServer.dispatch(server, event)
    assert_receive {:bridge_called, "hello", %{run_id: "fixed-run-id"}}
    assert_receive {:egress_called, "feishu:u300", %FinalMessage{}}

    assert {:ok, :duplicate} = DispatchServer.dispatch(server, event)
    refute_receive {:bridge_called, "hello", %{run_id: "fixed-run-id"}}
    refute_receive {:egress_called, "feishu:u300", %FinalMessage{}}
    refute_receive {:egress_called, "feishu:u300", %ErrorMessage{}}
    _ = first_result
  end

  test "egress 失败返回 EGRESS_ERROR 时不缓存终态，可同 run_id 恢复重试" do
    Application.put_env(:men, :dispatch_server_test_fail_final_egress, :downstream_unavailable)

    server = start_dispatch_server()

    event = %{
      request_id: "req-egress-fail-1",
      run_id: "retryable-run-id",
      payload: "hello",
      channel: "feishu",
      user_id: "u301"
    }

    assert {:error, error_result} = DispatchServer.dispatch(server, event)
    assert error_result.code == "EGRESS_ERROR"
    assert_receive {:bridge_called, "hello", %{run_id: "retryable-run-id"}}

    Application.delete_env(:men, :dispatch_server_test_fail_final_egress)

    assert {:ok, result} = DispatchServer.dispatch(server, event)
    assert result.run_id == "retryable-run-id"
    assert_receive {:bridge_called, "hello", %{run_id: "retryable-run-id"}}

    assert {:ok, :duplicate} = DispatchServer.dispatch(server, event)
    refute_receive {:bridge_called, "hello", %{run_id: "retryable-run-id"}}
    _ = result
  end

  test "同 run_id 并发提交: 返回值为 {:ok, result} 与 {:ok, :duplicate}" do
    server = start_dispatch_server()

    event = %{
      request_id: "req-concurrent-1",
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
    assert Enum.any?(results, &match?({:ok, %{run_id: "concurrent-run-id"}}, &1))
    assert Enum.any?(results, &match?({:ok, :duplicate}, &1))

    assert_receive {:bridge_called, "hello", %{run_id: "concurrent-run-id"}}
    refute_receive {:bridge_called, "hello", %{run_id: "concurrent-run-id"}}

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

  test "streaming_enabled 打开时会透传 delta 事件" do
    server = start_dispatch_server(streaming_enabled: true)

    event = %{
      request_id: "req-stream-1",
      run_id: "run-stream-1",
      payload: "stream_delta",
      channel: "feishu",
      user_id: "u-stream"
    }

    assert {:ok, result} = DispatchServer.dispatch(server, event)
    assert result.run_id == "run-stream-1"

    assert_receive {:egress_called, "feishu:u-stream", %EventMessage{} = event_message}
    assert event_message.event_type == :delta
    assert event_message.payload == %{text: "partial:stream_delta"}
    assert event_message.metadata.run_id == "run-stream-1"

    assert_receive {:egress_called, "feishu:u-stream", %FinalMessage{} = final_message}
    assert final_message.content == "ok:stream_delta"
  end

  test "接收到非关键 session_event 时兜底吞掉，不影响进程存活" do
    server = start_dispatch_server()

    send(server, {:session_event, %{type: "lifecycle.received", session_id: "session-x", seq: 1}})
    Process.sleep(20)

    assert Process.alive?(server)
    refute_receive {:egress_called, _, _}
    refute_receive {:bridge_called, _, _}
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

  test "session coordinator 在 get_or_create_session 调用窗口退出时回退到原始 session_key" do
    coordinator_name = start_transient_coordinator(:crash_on_get_or_create_session)

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

  test "session coordinator 在 rebuild 调用窗口退出时保持单次失败语义" do
    coordinator_name = start_transient_coordinator(:crash_on_rebuild_session)

    server =
      start_dispatch_server(
        session_coordinator_enabled: true,
        session_coordinator_name: coordinator_name
      )

    event = %{
      request_id: "req-coord-race-2",
      payload: "session_not_found_once",
      channel: "feishu",
      user_id: "u-race-2"
    }

    assert {:error, error_result} = DispatchServer.dispatch(server, event)
    assert error_result.code == "session_not_found"
    assert error_result.reason == "runtime session missing"
    assert_receive {:egress_called, "feishu:u-race-2", %ErrorMessage{code: "session_not_found"}}
  end
end
