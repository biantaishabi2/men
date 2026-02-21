defmodule Men.Channels.Egress.RouterAdapterTest do
  use ExUnit.Case, async: true

  alias Men.Channels.Egress.Messages.FinalMessage
  alias Men.Channels.Egress.RouterAdapter

  test "未知渠道返回错误" do
    message = %FinalMessage{session_key: "unknown:u1", content: "hi", metadata: %{}}
    assert {:error, :unsupported_channel} = RouterAdapter.send("unknown:u1", message)
  end
end
