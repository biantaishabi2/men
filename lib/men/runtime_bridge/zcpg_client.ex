defmodule Men.RuntimeBridge.ZcpgClient do
  @moduledoc """
  zcpg client 兼容入口：提供 callback 场景统一调用入口。
  """

  @spec start_turn(binary(), map() | keyword()) :: {:ok, map()} | {:error, map()}
  def start_turn(prompt, context) do
    Men.Bridge.ZcpgClient.start_turn(prompt, context)
  end
end
