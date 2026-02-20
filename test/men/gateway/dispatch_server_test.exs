defmodule Men.Gateway.DispatchServerTest do
  use ExUnit.Case, async: false

  alias Men.Channels.Egress.Messages.{ErrorMessage, FinalMessage}
  alias Men.Gateway.DispatchServer

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      notify({:bridge_called, prompt, context})

      if prompt == "bridge_error" do
        {:error,
         %{
           type: :failed,
           code: "BRIDGE_FAIL",
           message: "runtime bridge failed",
           details: %{source: :mock}
         }}
      else
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
    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(target, message) do
      notify({:egress_called, target, message})
      :ok
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :dispatch_server_test_pid) do
        send(pid, message)
      end

      :ok
    end
  end

  setup do
    Application.put_env(:men, :dispatch_server_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:men, :dispatch_server_test_pid)
    end)

    :ok
  end

  test "有效 inbound event: bridge 成功并触发 final egress" do
    server =
      start_supervised!(
        {DispatchServer, bridge_adapter: MockBridge, egress_adapter: MockEgress}
      )

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

    assert_receive {:bridge_called, "hello", %{request_id: "req-1", run_id: run_id, session_key: "feishu:u100"}}
    assert run_id == result.run_id

    assert_receive {:egress_called, "feishu:u100", %FinalMessage{} = message}
    assert message.content == "ok:hello"
    assert message.metadata.request_id == "req-1"
    assert message.metadata.run_id == result.run_id
  end

  test "bridge error: 触发 error egress 并返回 error_result" do
    server =
      start_supervised!(
        {DispatchServer, bridge_adapter: MockBridge, egress_adapter: MockEgress}
      )

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

  test "重复 run_id: 返回 duplicate 且不重复 egress" do
    server =
      start_supervised!(
        {DispatchServer, bridge_adapter: MockBridge, egress_adapter: MockEgress}
      )

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

  test "同 session 连续消息: session_key 一致且可连续处理" do
    server =
      start_supervised!(
        {DispatchServer, bridge_adapter: MockBridge, egress_adapter: MockEgress}
      )

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
end
