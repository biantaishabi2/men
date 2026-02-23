defmodule Men.Integration.MenZcpgCutoverTest do
  use ExUnit.Case, async: false

  alias Men.Channels.Egress.Messages.FinalMessage
  alias Men.Gateway.DispatchServer

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, _context),
      do: {:ok, %{text: "ok:" <> prompt, meta: %{source: :cutover}}}
  end

  defmodule MockEgress do
    import Kernel, except: [send: 2]

    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(target, %FinalMessage{} = message) do
      if pid = Application.get_env(:men, :cutover_test_pid) do
        Kernel.send(pid, {:egress_called, target, message})
      end

      :ok
    end

    def send(_target, _message), do: :ok
  end

  setup do
    Application.put_env(:men, :cutover_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:men, :cutover_test_pid)
    end)

    :ok
  end

  test "事件协调入口新增后 dispatch 主链路语义不回归" do
    server =
      start_supervised!(
        {DispatchServer,
         name: {:global, {__MODULE__, self(), make_ref()}},
         bridge_adapter: MockBridge,
         egress_adapter: MockEgress,
         session_coordinator_enabled: false}
      )

    assert {:ok, result} =
             DispatchServer.dispatch(server, %{
               request_id: "req-cutover-1",
               payload: "hello",
               channel: "feishu",
               user_id: "u-cutover"
             })

    assert result.session_key == "feishu:u-cutover"
    assert_receive {:egress_called, "feishu:u-cutover", %FinalMessage{content: "ok:hello"}}
  end
end
