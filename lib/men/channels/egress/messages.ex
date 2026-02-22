defmodule Men.Channels.Egress.Messages.FinalMessage do
  @moduledoc """
  出站最终消息结构。
  """

  @enforce_keys [:session_key, :content]
  defstruct [:session_key, :content, metadata: %{}]

  @type t :: %__MODULE__{
          session_key: String.t(),
          content: String.t(),
          metadata: map()
        }
end

defmodule Men.Channels.Egress.Messages.ErrorMessage do
  @moduledoc """
  出站错误消息结构。
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
