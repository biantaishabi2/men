defmodule Men.RuntimeBridge.Error do
  @moduledoc """
  Runtime Bridge 内部错误结构（兼容旧桥接调用路径）。
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, retryable: false, context: %{}]

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          retryable: boolean(),
          context: map()
        }
end
