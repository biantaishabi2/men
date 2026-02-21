defmodule Men.Channels.Ingress.FeishuAdapterTest do
  use ExUnit.Case, async: false

  alias Men.Channels.Ingress.FeishuAdapter

  setup do
    Application.put_env(:men, FeishuAdapter,
      signing_secret: "test-secret",
      sign_mode: :strict
    )

    on_exit(fn ->
      Application.delete_env(:men, FeishuAdapter)
    end)

    :ok
  end

  test "合法签名请求可被标准化为 inbound event" do
    timestamp = System.system_time(:second)
    nonce = "nonce-ok-1"
    body = valid_body("evt-ok-1", "hello")
    headers = signed_headers(timestamp, nonce, body)

    assert {:ok, event} = FeishuAdapter.normalize(%{headers: headers, body: body})
    assert event.request_id == "evt-ok-1"
    assert event.run_id == "evt-ok-1"
    assert event.payload == "hello"
    assert event.channel == "feishu"
    assert event.user_id == "ou_test_user"
    assert event.group_id == "oc_test_chat"
    assert event.metadata["reply_token"] == "om_test_message"
  end

  test "签名错误会被拒绝" do
    timestamp = System.system_time(:second)
    nonce = "nonce-bad-sign"
    body = valid_body("evt-bad-sign", "hello")

    headers =
      signed_headers(timestamp, nonce, body)
      |> Map.put("x-lark-signature", "invalid")

    assert {:error, :invalid_signature} = FeishuAdapter.normalize(%{headers: headers, body: body})
  end

  test "strict 模式时间窗为 ±5 分钟，超窗拒绝" do
    timestamp = System.system_time(:second) - 301
    nonce = "nonce-strict-window"
    body = valid_body("evt-window-strict", "hello")
    headers = signed_headers(timestamp, nonce, body)

    assert {:error, :timestamp_expired} = FeishuAdapter.normalize(%{headers: headers, body: body})
  end

  test "compat 模式时间窗放宽到 ±15 分钟且关闭 nonce 去重" do
    Application.put_env(:men, FeishuAdapter,
      signing_secret: "test-secret",
      sign_mode: :compat
    )

    timestamp = System.system_time(:second) - 600
    nonce = "nonce-compat-reused"
    body = valid_body("evt-compat", "hello")
    headers = signed_headers(timestamp, nonce, body)

    assert {:ok, _event1} = FeishuAdapter.normalize(%{headers: headers, body: body})
    assert {:ok, _event2} = FeishuAdapter.normalize(%{headers: headers, body: body})
  end

  test "strict 模式启用 nonce 去重，重放会被拒绝" do
    timestamp = System.system_time(:second)
    nonce = "nonce-strict-replay"
    body = valid_body("evt-strict-replay", "hello")
    headers = signed_headers(timestamp, nonce, body)

    assert {:ok, _event} = FeishuAdapter.normalize(%{headers: headers, body: body})
    assert {:error, :replay_detected} = FeishuAdapter.normalize(%{headers: headers, body: body})
  end

  test "strict 模式并发重放时仅允许一次通过" do
    timestamp = System.system_time(:second)
    nonce = "nonce-concurrent-#{System.unique_integer([:positive])}"
    body = valid_body("evt-concurrent-replay", "hello")
    headers = signed_headers(timestamp, nonce, body)

    results =
      1..20
      |> Task.async_stream(
        fn _ -> FeishuAdapter.normalize(%{headers: headers, body: body}) end,
        max_concurrency: 20,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    replay_count = Enum.count(results, &match?({:error, :replay_detected}, &1))

    assert ok_count == 1
    assert replay_count == 19
  end

  test "严格模式下 replay key 包含 bot 维度，不同 bot 不互相污染" do
    Application.put_env(:men, FeishuAdapter,
      sign_mode: :strict,
      bots: %{
        "cli_bot_a" => %{signing_secret: "secret-a"},
        "cli_bot_b" => %{signing_secret: "secret-b"}
      }
    )

    timestamp = System.system_time(:second)
    nonce = "nonce-cross-bot"
    body_a = valid_body("evt-cross-bot-a", "hello-a", "cli_bot_a")
    body_b = valid_body("evt-cross-bot-b", "hello-b", "cli_bot_b")
    headers_a = signed_headers(timestamp, nonce, body_a, "secret-a")
    headers_b = signed_headers(timestamp, nonce, body_b, "secret-b")

    assert {:ok, _event_a} = FeishuAdapter.normalize(%{headers: headers_a, body: body_a})
    assert {:ok, _event_b} = FeishuAdapter.normalize(%{headers: headers_b, body: body_b})
  end

  test "支持仅 per-bot signing_secret 配置，无全局 secret" do
    Application.put_env(:men, FeishuAdapter,
      sign_mode: :strict,
      bots: %{
        "cli_test_bot" => %{signing_secret: "bot-only-secret"}
      }
    )

    timestamp = System.system_time(:second)
    nonce = "nonce-bot-only-secret"
    body = valid_body("evt-bot-only-secret", "hello")
    headers = signed_headers(timestamp, nonce, body, "bot-only-secret")

    assert {:ok, _event} = FeishuAdapter.normalize(%{headers: headers, body: body})
  end

  defp valid_body(event_id, text, app_id \\ "cli_test_bot") do
    Jason.encode!(%{
      "schema" => "2.0",
      "header" => %{
        "event_id" => event_id,
        "event_type" => "im.message.receive_v1",
        "create_time" => "1700000000000",
        "app_id" => app_id
      },
      "event" => %{
        "sender" => %{
          "sender_id" => %{
            "open_id" => "ou_test_user"
          }
        },
        "message" => %{
          "message_id" => "om_test_message",
          "chat_id" => "oc_test_chat",
          "chat_type" => "group",
          "content" => Jason.encode!(%{"text" => text})
        }
      }
    })
  end

  defp signed_headers(timestamp, nonce, body, secret \\ "test-secret") do
    base = "#{timestamp}\n#{nonce}\n#{body}"

    signature =
      :crypto.mac(:hmac, :sha256, secret, base)
      |> Base.encode64()

    %{
      "x-lark-signature" => signature,
      "x-lark-request-timestamp" => Integer.to_string(timestamp),
      "x-lark-nonce" => nonce
    }
  end
end
