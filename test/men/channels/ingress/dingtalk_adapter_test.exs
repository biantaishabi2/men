defmodule Men.Channels.Ingress.DingtalkAdapterTest do
  use ExUnit.Case, async: true

  alias Men.Channels.Ingress.DingtalkAdapter

  setup do
    Application.put_env(:men, DingtalkAdapter,
      secret: "test-secret",
      signature_window_seconds: 300
    )

    on_exit(fn ->
      Application.delete_env(:men, DingtalkAdapter)
    end)

    :ok
  end

  test "验签通过并标准化为主链路事件" do
    body = %{
      "event_type" => "message",
      "event_id" => "evt-1",
      "sender_id" => "user-1",
      "conversation_id" => "conv-1",
      "content" => "hello dingtalk"
    }

    timestamp = System.system_time(:second)
    raw_body = Jason.encode!(body)

    request = %{
      headers: signed_headers(timestamp, raw_body),
      body: body,
      raw_body: raw_body
    }

    assert {:ok, event} = DingtalkAdapter.normalize(request)
    assert event.channel == "dingtalk"
    assert event.user_id == "user-1"
    assert event.request_id == "evt-1"

    assert event.payload == %{
             channel: "dingtalk",
             event_type: "message",
             sender_id: "user-1",
             conversation_id: "conv-1",
             content: "hello dingtalk",
             tenant_id: nil,
             mentioned: false,
             raw_payload: body
           }

    assert event.metadata.raw_payload == body
    assert event.metadata.mention_required == true
    assert event.metadata.mentioned == false
  end

  test "签名错误会被拒绝" do
    body = %{
      "event_type" => "message",
      "sender_id" => "user-1",
      "conversation_id" => "conv-1",
      "content" => "hello"
    }

    timestamp = System.system_time(:second)

    request = %{
      headers: %{
        "x-dingtalk-timestamp" => Integer.to_string(timestamp),
        "x-dingtalk-signature" => "wrong-signature"
      },
      body: body,
      raw_body: Jason.encode!(body)
    }

    assert {:error, error} = DingtalkAdapter.normalize(request)
    assert error.code == "INVALID_SIGNATURE"
  end

  test "缺失签名会返回 INVALID_SIGNATURE" do
    body = %{
      "event_type" => "message",
      "sender_id" => "user-1",
      "conversation_id" => "conv-1",
      "content" => "hello"
    }

    timestamp = System.system_time(:second)

    request = %{
      headers: %{
        "x-dingtalk-timestamp" => Integer.to_string(timestamp)
      },
      body: body,
      raw_body: Jason.encode!(body)
    }

    assert {:error, error} = DingtalkAdapter.normalize(request)
    assert error.code == "INVALID_SIGNATURE"
    assert error.details.field == :signature
  end

  test "缺失 raw_body 会被拒绝，不回退重编码验签" do
    body = %{
      "event_type" => "message",
      "sender_id" => "user-1",
      "conversation_id" => "conv-1",
      "content" => "hello"
    }

    timestamp = System.system_time(:second)
    raw_body = Jason.encode!(body)

    request = %{
      headers: signed_headers(timestamp, raw_body),
      body: body
    }

    assert {:error, error} = DingtalkAdapter.normalize(request)
    assert error.code == "INVALID_REQUEST"
    assert error.details.field == :raw_body
  end

  test "签名时间超窗会被拒绝" do
    body = %{
      "event_type" => "message",
      "sender_id" => "user-1",
      "conversation_id" => "conv-1",
      "content" => "hello"
    }

    timestamp = System.system_time(:second) - 301
    raw_body = Jason.encode!(body)

    request = %{
      headers: signed_headers(timestamp, raw_body),
      body: body,
      raw_body: raw_body
    }

    assert {:error, error} = DingtalkAdapter.normalize(request)
    assert error.code == "SIGNATURE_EXPIRED"
  end

  test "缺失关键字段返回字段错误并保留 raw_payload" do
    body = %{
      "event_type" => "message",
      "conversation_id" => "conv-1",
      "content" => "hello"
    }

    timestamp = System.system_time(:second)
    raw_body = Jason.encode!(body)

    request = %{
      headers: signed_headers(timestamp, raw_body),
      body: body,
      raw_body: raw_body
    }

    assert {:error, error} = DingtalkAdapter.normalize(request)
    assert error.code == "MISSING_FIELD"
    assert error.details.field == :sender_id
    assert error.details.raw_payload == body
  end

  defp signed_headers(timestamp, raw_body) do
    sign_input = Integer.to_string(timestamp) <> "\n" <> raw_body

    signature =
      :crypto.mac(:hmac, :sha256, "test-secret", sign_input)
      |> Base.encode64()

    %{
      "x-dingtalk-timestamp" => Integer.to_string(timestamp),
      "x-dingtalk-signature" => signature
    }
  end
end
