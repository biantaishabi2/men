defmodule Men.RuntimeBridge.Response do
  @moduledoc """
  Runtime 成功响应结构。
  """

  @enforce_keys [:session_key, :content]
  defstruct [:session_key, :content, metadata: %{}]

  @type t :: %__MODULE__{
          session_key: String.t(),
          content: String.t(),
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
