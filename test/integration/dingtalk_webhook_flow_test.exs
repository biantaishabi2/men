defmodule Men.Integration.DingtalkWebhookFlowTest do
  use MenWeb.ConnCase, async: false

  alias Men.Channels.Ingress.DingtalkAdapter
  alias Men.Gateway.DispatchServer
  alias Men.Gateway.SessionCoordinator

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      notify({:bridge_called, prompt, context})

      case decode_payload(prompt) do
        %{"content" => "session_not_found_once"} ->
          attempt = Process.get({:integration_bridge_attempt, context.run_id}, 0) + 1
          Process.put({:integration_bridge_attempt, context.run_id}, attempt)

          if attempt == 1 do
            {:error,
             %{
               type: :failed,
               code: "session_not_found",
               message: "runtime session missing",
               details: %{source: :integration}
             }}
          else
            {:ok, %{text: "bridge-final", meta: %{source: :integration}}}
          end

        %{"content" => "bridge_error"} ->
          {:error,
           %{
             type: :failed,
             code: "BRIDGE_FAIL",
             message: "runtime bridge failed",
             details: %{source: :integration}
           }}

        _ ->
          {:ok, %{text: "bridge-final", meta: %{source: :integration}}}
      end
    end

    defp decode_payload(prompt) do
      case Jason.decode(prompt) do
        {:ok, payload} -> payload
        _ -> %{}
      end
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :dingtalk_integration_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule MockDispatchEgress do
    import Kernel, except: [send: 2]

    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(target, message) do
      if pid = Application.get_env(:men, :dingtalk_integration_test_pid) do
        Kernel.send(pid, {:egress_called, target, message})
      end

      :ok
    end
  end

  setup do
    Application.put_env(:men, :dingtalk_integration_test_pid, self())

    coordinator_name = {:global, {__MODULE__, :coordinator, self(), make_ref()}}

    start_supervised!(
      {SessionCoordinator,
       name: coordinator_name,
       ttl_ms: 300_000,
       gc_interval_ms: 60_000,
       max_entries: 10_000,
       invalidation_codes: [:runtime_session_not_found, :session_not_found]}
    )

    server_name = {:global, {__MODULE__, self(), make_ref()}}

    start_supervised!(
      {DispatchServer,
       name: server_name,
       bridge_adapter: MockBridge,
       egress_adapter: MockDispatchEgress,
       session_coordinator_enabled: true,
       session_coordinator_name: coordinator_name}
    )

    Application.put_env(:men, MenWeb.Webhooks.DingtalkController,
      ingress_adapter: DingtalkAdapter,
      dispatch_server: server_name
    )

    Application.put_env(:men, DingtalkAdapter,
      secret: "integration-secret",
      signature_window_seconds: 300
    )

    on_exit(fn ->
      Application.delete_env(:men, :dingtalk_integration_test_pid)
      Application.delete_env(:men, MenWeb.Webhooks.DingtalkController)
      Application.delete_env(:men, DingtalkAdapter)
    end)

    :ok
  end

  test "连续 webhook 对话复用 runtime_session_id", %{conn: conn} do
    payload_1 = payload("evt-integration-1", "user-integration", "conv-integration", "turn-1")
    payload_2 = payload("evt-integration-2", "user-integration", "conv-integration", "turn-2")

    assert accepted?(post_signed(conn, payload_1))
    assert accepted?(post_signed(build_conn(), payload_2))

    assert_receive {:bridge_called, _, %{external_session_key: "dingtalk:user-integration", session_key: runtime_session_id_1}}
    assert_receive {:bridge_called, _, %{external_session_key: "dingtalk:user-integration", session_key: runtime_session_id_2}}

    assert runtime_session_id_1 == runtime_session_id_2

    assert_receive {:egress_called, "dingtalk:user-integration", %Men.Channels.Egress.Messages.FinalMessage{}}
    assert_receive {:egress_called, "dingtalk:user-integration", %Men.Channels.Egress.Messages.FinalMessage{}}
  end

  test "不同 session_key 并发 webhook 隔离", %{conn: conn} do
    payload_1 = payload("evt-integration-3", "user-a", "conv-a", "parallel-a")
    payload_2 = payload("evt-integration-4", "user-b", "conv-b", "parallel-b")

    tasks =
      [payload_1, payload_2]
      |> Enum.map(fn data ->
        Task.async(fn ->
          response_conn = post_signed(build_conn(), data)
          assert accepted?(response_conn)
        end)
      end)

    Enum.each(tasks, &Task.await(&1, 2_000))

    contexts =
      receive_n_bridge_contexts(2)
      |> Enum.sort_by(& &1.external_session_key)

    assert Enum.map(contexts, & &1.external_session_key) == ["dingtalk:user-a", "dingtalk:user-b"]
    assert Enum.uniq(Enum.map(contexts, & &1.session_key)) |> length() == 2

    assert_receive {:egress_called, "dingtalk:user-a", %Men.Channels.Egress.Messages.FinalMessage{}}
    assert_receive {:egress_called, "dingtalk:user-b", %Men.Channels.Egress.Messages.FinalMessage{}}
    _ = conn
  end

  test "session_not_found 在 webhook 主链路单次自愈且不重复出站", %{conn: conn} do
    event_payload = payload("evt-integration-5", "user-heal", "conv-heal", "session_not_found_once")

    assert accepted?(post_signed(conn, event_payload))

    assert_receive {:bridge_called, prompt, %{run_id: run_id, session_key: runtime_session_id_1}}
    assert_receive {:bridge_called, ^prompt, %{run_id: ^run_id, session_key: runtime_session_id_2}}
    assert runtime_session_id_1 != runtime_session_id_2

    assert_receive {:egress_called, "dingtalk:user-heal", %Men.Channels.Egress.Messages.FinalMessage{}}
    refute_receive {:egress_called, "dingtalk:user-heal", %Men.Channels.Egress.Messages.FinalMessage{}}
    refute_receive {:egress_called, "dingtalk:user-heal", %Men.Channels.Egress.Messages.ErrorMessage{}}
  end

  test "bridge 失败不影响 webhook 立即 ACK，后台按既有语义 error 回写", %{conn: conn} do
    event_payload = payload("evt-integration-6", "user-error", "conv-error", "bridge_error")

    assert accepted?(post_signed(conn, event_payload))

    assert_receive {:bridge_called, _, %{external_session_key: "dingtalk:user-error"}}
    assert_receive {:egress_called, "dingtalk:user-error", %Men.Channels.Egress.Messages.ErrorMessage{} = message}
    assert message.code == "BRIDGE_FAIL"
  end

  defp payload(event_id, sender_id, conversation_id, content) do
    %{
      "event_type" => "message",
      "event_id" => event_id,
      "sender_id" => sender_id,
      "conversation_id" => conversation_id,
      "content" => content
    }
  end

  defp post_signed(conn, payload) do
    timestamp = System.system_time(:second)
    raw_body = Jason.encode!(payload)

    signature =
      :crypto.mac(
        :hmac,
        :sha256,
        "integration-secret",
        Integer.to_string(timestamp) <> "\n" <> raw_body
      )
      |> Base.encode64()

    conn
    |> put_req_header("x-dingtalk-timestamp", Integer.to_string(timestamp))
    |> put_req_header("x-dingtalk-signature", signature)
    |> post("/webhooks/dingtalk", payload)
  end

  defp accepted?(conn) do
    body = json_response(conn, 200)
    body["status"] == "accepted" and body["code"] == "ACCEPTED"
  end

  defp receive_n_bridge_contexts(count) do
    1..count
    |> Enum.map(fn _ ->
      assert_receive {:bridge_called, _, context}
      context
    end)
  end
end
