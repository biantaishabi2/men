defmodule Men.Gateway.PromptComposerTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.PromptComposer

  test "frame 有有效内容时注入 HUD" do
    frame = %{
      inbox: [%{role: "user", content: "hello"}],
      pending_actions: [],
      recent_receipts: [],
      budget: %{tokens: 16_000, messages: 20}
    }

    composed = PromptComposer.compose("base", frame, inject?: true)

    assert composed.frame_injected? == true
    assert String.contains?(composed.prompt, "[HUD]")
  end

  test "空 frame 保持非 action 兼容路径" do
    frame = %{
      inbox: [],
      pending_actions: [],
      recent_receipts: [],
      budget: %{tokens: 16_000, messages: 20}
    }

    composed = PromptComposer.compose("base", frame, inject?: true)

    assert composed.frame_injected? == false
    assert composed.prompt == "base"
  end
end
