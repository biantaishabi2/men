defmodule Men.Integration.MenZcpgCutoverTest do
  use ExUnit.Case, async: false

  alias Men.Gateway.DispatchServer

  defmodule MockZcpgClient do
    def start_turn(prompt, context) do
      notify({:zcpg_called, prompt, context})

      case Jason.decode(prompt) do
        {:ok, %{"content" => "@bot timeout"}} ->
          {:error,
           %{
             type: :timeout,
             code: "timeout",
             message: "zcpg timeout",
             details: %{source: :mock},
             fallback: true
           }}

        _ ->
          {:ok, %{text: "zcpg-final", meta: %{source: :zcpg_mock}}}
      end
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :men_zcpg_cutover_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule MockLegacyBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      notify({:legacy_called, prompt, context})
      {:ok, %{text: "legacy-final", meta: %{source: :legacy_mock}}}
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :men_zcpg_cutover_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule MockEgress do
    import Kernel, except: [send: 2]

    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(target, message) do
      if pid = Application.get_env(:men, :men_zcpg_cutover_test_pid) do
        Kernel.send(pid, {:egress_called, target, message})
      end

      :ok
    end
  end

  setup do
    Application.put_env(:men, :men_zcpg_cutover_test_pid, self())

    server_name = {:global, {__MODULE__, self(), make_ref()}}

    start_supervised!(
      {DispatchServer,
       name: server_name,
       legacy_bridge_adapter: MockLegacyBridge,
       zcpg_client: MockZcpgClient,
       egress_adapter: MockEgress,
       session_coordinator_enabled: false,
       zcpg_cutover_config: [
         enabled: true,
         tenant_whitelist: ["tenantA"],
         env_override: false,
         timeout_ms: 2_000,
         breaker: [failure_threshold: 5, window_seconds: 30, cooldown_seconds: 60]
       ]}
    )

    on_exit(fn ->
      Application.delete_env(:men, :men_zcpg_cutover_test_pid)
    end)

    {:ok, server: server_name}
  end

  test "@消息白名单租户走 zcpg 并回包", %{server: server} do
    event = %{
      request_id: "req-zcpg-ok-1",
      payload: %{channel: "dingtalk", content: "@bot 你好", tenant_id: "tenantA"},
      channel: "dingtalk",
      user_id: "u-zcpg-ok",
      metadata: %{tenant_id: "tenantA", mention_required: true, mentioned: true}
    }

    assert {:ok, result} = DispatchServer.dispatch(server, event)
    assert result.payload.text == "zcpg-final"

    assert_receive {:zcpg_called, _, _}
    refute_receive {:legacy_called, _, _}

    assert_receive {:egress_called, "dingtalk:u-zcpg-ok",
                    %Men.Channels.Egress.Messages.FinalMessage{} = message}

    assert message.content == "zcpg-final"
  end

  test "zcpg 不可用时自动回退 legacy 并持续回包", %{server: server} do
    event = %{
      request_id: "req-zcpg-fallback-1",
      payload: %{channel: "dingtalk", content: "@bot timeout", tenant_id: "tenantA"},
      channel: "dingtalk",
      user_id: "u-zcpg-fallback",
      metadata: %{tenant_id: "tenantA", mention_required: true, mentioned: true}
    }

    assert {:ok, result} = DispatchServer.dispatch(server, event)
    assert result.payload.text == "legacy-final"

    assert_receive {:zcpg_called, _, _}
    assert_receive {:legacy_called, _, _}

    assert_receive {:egress_called, "dingtalk:u-zcpg-fallback",
                    %Men.Channels.Egress.Messages.FinalMessage{} = message}

    assert message.content == "legacy-final"
  end
end
