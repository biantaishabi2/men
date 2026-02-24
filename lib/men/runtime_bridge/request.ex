defmodule Men.RuntimeBridge.Request do
  @moduledoc """
  Runtime 调用请求结构（兼容新旧字段）。
  """

  defstruct [
    :runtime_id,
    :session_id,
    :payload,
    :timeout_ms,
    :session_key,
    :content,
    opts: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          runtime_id: String.t() | nil,
          session_id: String.t() | nil,
          payload: term() | nil,
          timeout_ms: pos_integer() | nil,
          session_key: String.t() | nil,
          content: String.t() | nil,
          opts: map(),
          metadata: map()
        }
end
