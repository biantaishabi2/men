defmodule Men.Gateway.PromptComposer do
  @moduledoc """
  将主循环 frame 注入 prompt 上下文（HUD），并保留非 action 兼容路径。
  """

  @spec compose(binary(), map(), keyword()) :: %{
          prompt: binary(),
          hud: binary() | nil,
          frame_injected?: boolean()
        }
  def compose(prompt, frame, opts \\ []) when is_binary(prompt) and is_map(frame) do
    inject? = Keyword.get(opts, :inject?, true)

    if inject? and should_inject?(frame) do
      hud = encode_hud(frame)

      %{
        prompt: prompt <> "\n\n[HUD]\n" <> hud,
        hud: hud,
        frame_injected?: true
      }
    else
      %{prompt: prompt, hud: nil, frame_injected?: false}
    end
  end

  defp should_inject?(frame) do
    has_inbox? = frame |> Map.get(:inbox, []) |> List.wrap() |> Enum.any?()
    has_pending? = frame |> Map.get(:pending_actions, []) |> List.wrap() |> Enum.any?()
    has_receipts? = frame |> Map.get(:recent_receipts, []) |> List.wrap() |> Enum.any?()
    has_inbox? or has_pending? or has_receipts?
  end

  defp encode_hud(frame) do
    Jason.encode!(%{frame: frame})
  rescue
    _ -> "{}"
  end
end
