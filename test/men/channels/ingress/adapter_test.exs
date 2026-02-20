defmodule Men.Channels.Ingress.AdapterTest do
  use ExUnit.Case, async: true

  alias Men.Channels.Ingress.Event

  defmodule MockIngressAdapter do
    @behaviour Men.Channels.Ingress.Adapter

    @impl true
    def normalize(%{text: text, user: user, channel: channel}) do
      {:ok,
       %Event{
         channel: channel,
         user_id: user,
         content: text,
         metadata: %{source: :mock},
         timestamp: DateTime.utc_now()
       }}
    end

    def normalize(_), do: {:error, :invalid_payload}
  end

  test "Event 结构体可构造" do
    now = DateTime.utc_now()

    event = %Event{
      channel: "feishu",
      user_id: "u1",
      group_id: "g1",
      thread_id: "t1",
      content: "hello",
      metadata: %{lang: "zh"},
      timestamp: now
    }

    assert event.channel == "feishu"
    assert event.user_id == "u1"
    assert event.metadata == %{lang: "zh"}
    assert event.timestamp == now
  end

  test "mock adapter 满足 behaviour 并返回统一 Event" do
    payload = %{text: "hi", user: "u1", channel: "feishu"}

    assert {:ok, %Event{} = event} = MockIngressAdapter.normalize(payload)
    assert event.channel == "feishu"
    assert event.user_id == "u1"
    assert event.content == "hi"
    assert event.metadata == %{source: :mock}
  end
end
