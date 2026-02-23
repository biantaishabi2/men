defmodule Men.Bridge.ZcpgClient do
  @moduledoc """
  兼容层：保留历史模块名，统一转发到 RuntimeBridge 实现。
  """

  @spec start_turn(binary(), map() | keyword()) :: {:ok, map()} | {:error, map()}
  def start_turn(prompt, context), do: Men.RuntimeBridge.ZcpgClient.start_turn(prompt, context)
end
