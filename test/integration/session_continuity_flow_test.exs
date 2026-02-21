defmodule Men.Integration.SessionContinuityFlowTest do
  use ExUnit.Case, async: false

  alias Men.Gateway.DispatchServer

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      if pid = Application.get_env(:men, :session_continuity_test_pid) do
        send(pid, {:bridge_called, prompt, context})
      end

      {:ok, %{status: :ok, text: "ok:" <> prompt, meta: %{source: :mock}}}
    end
  end

  defmodule MockEgress do
    import Kernel, except: [send: 2]
    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(_target, message) do
      if pid = Application.get_env(:men, :session_continuity_test_pid) do
        Kernel.send(pid, {:egress_called, message})
      end

      :ok
    end
  end

  setup do
    Application.put_env(:men, :session_continuity_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:men, :session_continuity_test_pid)
    end)

    :ok
  end

  test "同 session 连续消息：session_key 稳定，run_id 唯一" do
    server =
      start_supervised!(
        {DispatchServer,
         name: {:global, {__MODULE__, self(), make_ref()}},
         bridge_adapter: MockBridge,
         egress_adapter: MockEgress}
      )

    event1 = %{
      request_id: "req-s-1",
      payload: "hello-1",
      channel: "feishu",
      event_type: "message",
      user_id: "u-session",
      thread_id: "thread-1"
    }

    event2 = %{event1 | request_id: "req-s-2", payload: "hello-2"}

    assert {:ok, result1} = DispatchServer.dispatch(server, event1)
    assert {:ok, result2} = DispatchServer.dispatch(server, event2)

    assert result1.session_key == "feishu:u-session:t:thread-1"
    assert result2.session_key == "feishu:u-session:t:thread-1"
    refute result1.run_id == result2.run_id

    assert_receive {:bridge_called, "hello-1", %{run_id: run_id_1}}
    assert_receive {:bridge_called, "hello-2", %{run_id: run_id_2}}
    refute run_id_1 == run_id_2
  end
end
