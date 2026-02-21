defmodule Men.Gateway.DispatchServerTest do
  use ExUnit.Case, async: false

  alias Men.Channels.Egress.Messages.{ErrorMessage, FinalMessage}
  alias Men.Gateway.DispatchServer

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      if pid = Application.get_env(:men, :dispatch_server_test_pid) do
        send(pid, {:bridge_called, prompt, context})
      end

      case prompt do
        "timeout" ->
          {:error, %{status: :timeout, type: :timeout, message: "bridge timeout", details: %{source: :mock}}}

        "error" ->
          {:error, %{status: :error, type: :failed, message: "bridge failed", details: %{source: :mock}}}

        _ ->
          {:ok, %{status: :ok, text: "ok:" <> prompt, meta: %{source: :mock}}}
      end
    end
  end

  defmodule MockEgress do
    import Kernel, except: [send: 2]

    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(target, message) do
      if pid = Application.get_env(:men, :dispatch_server_test_pid) do
        Kernel.send(pid, {:egress_called, target, message})
      end

      case {Application.get_env(:men, :dispatch_server_test_fail_mode), message} do
        {:final, %FinalMessage{}} -> {:error, :egress_down}
        {:error, %ErrorMessage{}} -> {:error, :egress_down}
        _ -> :ok
      end
    end
  end

  setup do
    Application.put_env(:men, :dispatch_server_test_pid, self())
    Application.delete_env(:men, :dispatch_server_test_fail_mode)

    on_exit(fn ->
      Application.delete_env(:men, :dispatch_server_test_pid)
      Application.delete_env(:men, :dispatch_server_test_fail_mode)
    end)

    :ok
  end

  defp start_dispatch_server do
    start_supervised!(
      {DispatchServer,
       name: {:global, {__MODULE__, self(), make_ref()}},
       bridge_adapter: MockBridge,
       egress_adapter: MockEgress}
    )
  end

  defp base_event(payload) do
    %{
      request_id: "req-1",
      payload: payload,
      channel: "feishu",
      event_type: "message",
      user_id: "u100",
      metadata: %{"reply_token" => "m-1"}
    }
  end

  test "状态机成功路径：bridge ok -> final egress ok" do
    server = start_dispatch_server()

    assert {:ok, result} = DispatchServer.dispatch(server, base_event("hello"))
    assert result.request_id == "req-1"
    assert result.session_key == "feishu:u100"
    assert is_binary(result.run_id)
    assert result.payload.text == "ok:hello"

    assert_receive {:bridge_called, "hello", context}
    assert context.request_id == "req-1"
    assert context.session_key == "feishu:u100"
    assert context.event_type == "message"

    assert_receive {:egress_called, _target, %FinalMessage{} = final_msg}
    assert final_msg.content == "ok:hello"
  end

  test "状态机错误映射：bridge timeout -> bridge_timeout" do
    server = start_dispatch_server()

    assert {:error, error_result} = DispatchServer.dispatch(server, base_event("timeout"))
    assert error_result.code == "bridge_timeout"
    assert error_result.reason == "bridge timeout"

    assert_receive {:egress_called, _target, %ErrorMessage{} = error_msg}
    assert error_msg.code == "bridge_timeout"
    assert error_msg.reason == "bridge timeout"
  end

  test "状态机错误映射：bridge error -> bridge_error" do
    server = start_dispatch_server()

    assert {:error, error_result} = DispatchServer.dispatch(server, base_event("error"))
    assert error_result.code == "bridge_error"
    assert error_result.reason == "bridge failed"

    assert_receive {:egress_called, _target, %ErrorMessage{} = error_msg}
    assert error_msg.code == "bridge_error"
    assert error_msg.reason == "bridge failed"
  end

  test "状态机错误映射：egress fail -> egress_fail" do
    Application.put_env(:men, :dispatch_server_test_fail_mode, :final)
    server = start_dispatch_server()

    assert {:error, error_result} = DispatchServer.dispatch(server, base_event("hello"))
    assert error_result.code == "egress_fail"
    assert error_result.reason == "egress send failed"

    assert_receive {:egress_called, _target, %FinalMessage{}}
  end
end
