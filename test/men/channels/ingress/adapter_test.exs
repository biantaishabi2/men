defmodule Men.Channels.Ingress.AdapterTest do
  use ExUnit.Case, async: true

  defmodule MockIngressAdapter do
    @behaviour Men.Channels.Ingress.Adapter

    @impl true
    def normalize(%{text: text, user: user, channel: channel, event_type: event_type}) do
      {:ok,
       %{
         request_id: "req-1",
         payload: text,
         channel: channel,
         event_type: event_type,
         user_id: user,
         metadata: %{"source" => "mock"}
       }}
    end

    def normalize(%{mode: :signature_invalid}), do: {:error, :signature_invalid}
    def normalize(_), do: {:error, :invalid_payload}
  end

  test "mock adapter 返回标准 inbound_event" do
    payload = %{text: "hi", user: "u1", channel: "feishu", event_type: "message"}

    assert {:ok, event} = MockIngressAdapter.normalize(payload)
    assert event.request_id == "req-1"
    assert event.payload == "hi"
    assert event.channel == "feishu"
    assert event.event_type == "message"
    assert event.user_id == "u1"
  end

  test "mock adapter 可返回统一签名错误" do
    assert {:error, :signature_invalid} = MockIngressAdapter.normalize(%{mode: :signature_invalid})
  end
end
