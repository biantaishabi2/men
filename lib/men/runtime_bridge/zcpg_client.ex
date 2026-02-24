defmodule Men.RuntimeBridge.ZcpgClient do
  @moduledoc """
  zcpg 调用兼容入口，统一转发到 ZcpgRPC。
  """

  @spec start_turn(binary(), map() | keyword()) :: {:ok, map()} | {:error, map()}
  def start_turn(prompt, context), do: Men.RuntimeBridge.ZcpgRPC.start_turn(prompt, context)
end

