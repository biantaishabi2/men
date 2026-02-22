defmodule Men.RuntimeBridge.Response do
  @moduledoc """
  RuntimeBridge v1 统一成功响应模型。
  """

  @enforce_keys [:runtime_id]
  defstruct [:runtime_id, :session_id, :payload, metadata: %{}]

  @type t :: %__MODULE__{
          runtime_id: String.t(),
          session_id: String.t() | nil,
          payload: term() | nil,
          metadata: map()
        }
end

defmodule Men.RuntimeBridge.Error do
  @moduledoc """
  RuntimeBridge v1 统一错误模型。
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

defmodule Men.RuntimeBridge.ErrorResponse do
  @moduledoc """
  旧版 Runtime 错误结构（已废弃，仅用于兼容旧入口）。
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
