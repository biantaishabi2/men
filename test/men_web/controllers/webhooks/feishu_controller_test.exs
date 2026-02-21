defmodule MenWeb.Webhooks.FeishuControllerTest do
  use MenWeb.ConnCase, async: false

  alias Men.Channels.Egress.FeishuAdapter
  alias Men.Gateway.DispatchServer

  defmodule MockTransport do
    @behaviour Men.Channels.Egress.FeishuAdapter.HttpTransport

    @impl true
    def post(url, headers, body, _opts) do
      if pid = Application.get_env(:men, :feishu_webhook_test_pid) do
        send(pid, {:transport_post, url, headers, body})
      end

      {:ok, %{status: 200, body: ~s({"code":0})}}
    end
  end

  defmodule BridgeOK do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, _context) do
      {:ok, %{text: "ok:" <> prompt, meta: %{source: :test}}}
    end
  end

  defmodule BridgeFail do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(_prompt, _context) do
      {:error,
       %{
         type: :failed,
         code: "BRIDGE_FAIL",
         message: "runtime bridge failed",
         details: %{source: :test}
       }}
    end
  end

  setup do
    Application.put_env(:men, :feishu_webhook_test_pid, self())

    Application.put_env(:men, Men.Channels.Ingress.FeishuAdapter,
      signing_secret: "test-secret",
      sign_mode: :strict
    )

    Application.put_env(:men, FeishuAdapter,
      transport: MockTransport,
      bots: %{"cli_test_bot" => %{access_token: "bot-token"}}
    )

    on_exit(fn ->
      Application.delete_env(:men, :feishu_webhook_test_pid)
      Application.delete_env(:men, Men.Channels.Ingress.FeishuAdapter)
      Application.delete_env(:men, FeishuAdapter)
      Application.delete_env(:men, MenWeb.Webhooks.FeishuController)
    end)

    :ok
  end

  test "合法签名 webhook 返回 200 并进入 dispatch 主链路", %{conn: conn} do
    server = start_dispatch_server(BridgeOK)
    test_pid = self()

    Application.put_env(:men, MenWeb.Webhooks.FeishuController,
      dispatch_fun: fn event ->
        send(test_pid, {:dispatch_called, event})
        DispatchServer.dispatch(server, event)
      end
    )

    body = fixture_raw("feishu/happy_path.json")
    conn = request_with_signature(conn, body, "nonce-http-ok")
    conn = post(conn, "/webhooks/feishu", body)

    assert json_response(conn, 200)["status"] == "accepted"
    assert_receive {:dispatch_called, event}, 1_000
    assert event.request_id == "evt-feishu-happy-path"
    assert event.run_id == "evt-feishu-happy-path"
    assert event.channel == "feishu"
    assert event.user_id == "ou_test_user"
    assert event.group_id == "oc_test_chat"

    assert_receive {:transport_post, _url, _headers, payload}
    decoded = Jason.decode!(payload)
    assert decoded["content"]["text"] == "ok:hello"
  end

  test "非法签名 webhook 返回 401 且不触发 dispatch", %{conn: conn} do
    Application.put_env(:men, MenWeb.Webhooks.FeishuController,
      dispatch_fun: fn event ->
        send(self(), {:dispatch_called, event})
        {:ok, :ignored}
      end
    )

    body = fixture_raw("feishu/invalid_signature.json")
    conn = request_with_signature(conn, body, "nonce-http-bad")
    conn = put_req_header(conn, "x-lark-signature", "broken-signature")
    conn = post(conn, "/webhooks/feishu", body)

    assert json_response(conn, 401)["error"] == "unauthorized"
    refute_receive {:dispatch_called, _}
  end

  test "bridge 失败时 webhook 仍返回 200 并触发 error_reply", %{conn: conn} do
    server = start_dispatch_server(BridgeFail)
    test_pid = self()

    Application.put_env(:men, MenWeb.Webhooks.FeishuController,
      dispatch_fun: fn event ->
        send(test_pid, {:dispatch_called, event})
        DispatchServer.dispatch(server, event)
      end
    )

    body = fixture_raw("feishu/bridge_fail.json")
    conn = request_with_signature(conn, body, "nonce-http-bridge-fail")
    conn = post(conn, "/webhooks/feishu", body)

    assert json_response(conn, 200)["status"] == "accepted"
    assert_receive {:dispatch_called, event}, 1_000
    assert event.request_id == "evt-feishu-bridge-fail"
    assert event.run_id == "evt-feishu-bridge-fail"
    assert event.channel == "feishu"
    assert event.user_id == "ou_test_user"
    assert event.group_id == "oc_test_chat"

    assert_receive {:transport_post, _url, _headers, payload}

    decoded = Jason.decode!(payload)
    assert decoded["content"]["text"] == "[ERROR][BRIDGE_FAIL] runtime bridge failed"
  end

  defp start_dispatch_server(bridge_adapter) do
    start_supervised!(
      {DispatchServer,
       name: {:global, {__MODULE__, bridge_adapter, self(), make_ref()}},
       bridge_adapter: bridge_adapter,
       egress_adapter: FeishuAdapter}
    )
  end

  defp request_with_signature(conn, body, nonce) do
    timestamp = System.system_time(:second)
    base = "#{timestamp}\n#{nonce}\n#{body}"

    signature =
      :crypto.mac(:hmac, :sha256, "test-secret", base)
      |> Base.encode64()

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-lark-request-timestamp", Integer.to_string(timestamp))
    |> put_req_header("x-lark-nonce", nonce)
    |> put_req_header("x-lark-signature", signature)
  end

  defp fixture_raw(path) do
    "test/support/fixtures/webhooks"
    |> Path.join(path)
    |> File.read!()
    |> String.trim()
  end
end
