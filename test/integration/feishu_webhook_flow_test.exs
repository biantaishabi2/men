defmodule Men.Integration.FeishuWebhookFlowTest do
  use MenWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Men.Channels.Egress.FeishuAdapter
  alias Men.Gateway.DispatchServer

  defmodule MockTransport do
    @behaviour Men.Channels.Egress.FeishuAdapter.HttpTransport

    @impl true
    def post(url, headers, body, _opts) do
      if pid = Application.get_env(:men, :feishu_integration_test_pid) do
        send(pid, {:transport_post, url, headers, body})
      end

      {:ok, %{status: 200, body: ~s({"code":0})}}
    end
  end

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, _context) do
      case prompt do
        "bridge_fail" ->
          {:error, %{status: :error, type: :failed, message: "bridge failed", details: %{source: :mock}}}

        _ ->
          {:ok, %{status: :ok, text: "ok:" <> prompt, meta: %{source: :mock}}}
      end
    end
  end

  setup do
    Application.put_env(:men, :feishu_integration_test_pid, self())

    Application.put_env(:men, Men.Channels.Ingress.FeishuAdapter,
      signing_secret: "integration-secret",
      sign_mode: :strict
    )

    Application.put_env(:men, FeishuAdapter,
      transport: MockTransport,
      bots: %{"cli_test_bot" => %{access_token: "bot-token"}}
    )

    server_name = {:global, {__MODULE__, self(), make_ref()}}

    start_supervised!(
      {DispatchServer,
       name: server_name,
       bridge_adapter: MockBridge,
       egress_adapter: FeishuAdapter}
    )

    Application.put_env(:men, MenWeb.Webhooks.FeishuController,
      dispatch_server: server_name
    )

    on_exit(fn ->
      Application.delete_env(:men, :feishu_integration_test_pid)
      Application.delete_env(:men, Men.Channels.Ingress.FeishuAdapter)
      Application.delete_env(:men, FeishuAdapter)
      Application.delete_env(:men, MenWeb.Webhooks.FeishuController)
    end)

    :ok
  end

  test "happy path: ACK + final 回写", %{conn: conn} do
    body = valid_body("evt-feishu-1", "hello")
    conn = request_with_signature(conn, body, "nonce-1")
    conn = post(conn, "/webhooks/feishu", body)

    assert json_response(conn, 200)["status"] == "accepted"
    assert_receive {:transport_post, _url, _headers, payload}, 1_000
    assert Jason.decode!(payload)["content"]["text"] == "ok:hello"
  end

  test "signature fail: 请求被拒绝，bridge 不执行", %{conn: conn} do
    body = valid_body("evt-feishu-2", "hello")
    conn = request_with_signature(conn, body, "nonce-2")
    conn = put_req_header(conn, "x-lark-signature", "broken-sign")
    conn = post(conn, "/webhooks/feishu", body)

    assert json_response(conn, 401)["error"] == "unauthorized"
    refute_receive {:transport_post, _url, _headers, _body}
  end

  test "bridge fail: 触发错误摘要回写", %{conn: conn} do
    body = valid_body("evt-feishu-3", "bridge_fail")
    conn = request_with_signature(conn, body, "nonce-3")

    log =
      capture_log(fn ->
        conn = post(conn, "/webhooks/feishu", body)
        assert json_response(conn, 200)["status"] == "accepted"
      end)

    assert_receive {:transport_post, _url, _headers, payload}, 1_000
    assert Jason.decode!(payload)["content"]["text"] == "[ERROR][bridge_error] bridge failed"
    assert log =~ "gateway.dispatch"
    assert log =~ "request_id="
    assert log =~ "session_key="
    assert log =~ "run_id="
  end

  defp valid_body(event_id, text) do
    Jason.encode!(%{
      "schema" => "2.0",
      "header" => %{
        "event_id" => event_id,
        "event_type" => "im.message.receive_v1",
        "create_time" => "1700000000000",
        "app_id" => "cli_test_bot"
      },
      "event" => %{
        "sender" => %{"sender_id" => %{"open_id" => "ou_test_user"}},
        "message" => %{
          "message_id" => "om_test_message",
          "chat_id" => "oc_test_chat",
          "chat_type" => "group",
          "content" => Jason.encode!(%{"text" => text})
        }
      }
    })
  end

  defp request_with_signature(conn, body, nonce) do
    timestamp = System.system_time(:second)
    base = "#{timestamp}\n#{nonce}\n#{body}"

    signature =
      :crypto.mac(:hmac, :sha256, "integration-secret", base)
      |> Base.encode64()

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-lark-request-timestamp", Integer.to_string(timestamp))
    |> put_req_header("x-lark-nonce", nonce)
    |> put_req_header("x-lark-signature", signature)
  end
end
