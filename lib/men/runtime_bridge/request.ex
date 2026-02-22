defmodule Men.RuntimeBridge.Request do
  @moduledoc """
  Runtime 调用请求结构。
  """

  @enforce_keys [:session_key, :content]
  defstruct [:session_key, :content, metadata: %{}]

  @type t :: %__MODULE__{
          session_key: String.t(),
          content: String.t(),
          metadata: map()
        }
end
