defmodule Men.RuntimeBridge.Response do
  @moduledoc """
  Runtime 成功响应结构（兼容新旧字段）。
  """

  defstruct [
    :runtime_id,
    :session_id,
    :payload,
    :session_key,
    :content,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          runtime_id: String.t() | nil,
          session_id: String.t() | nil,
          payload: term() | nil,
          session_key: String.t() | nil,
          content: String.t() | nil,
          metadata: map()
        }
end

defmodule Men.RuntimeBridge.ErrorResponse do
  @moduledoc """
  Runtime 错误响应结构。
  """

  @enforce_keys [:session_key, :reason]
  defstruct [:session_key, :reason, code: nil, metadata: %{}]

  @type t :: %__MODULE__{
          session_key: String.t(),
          reason: String.t(),
          code: String.t() | nil,
          metadata: map()
        }
end
