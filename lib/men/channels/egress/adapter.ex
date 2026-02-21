defmodule Men.Channels.Egress.Adapter do
  @moduledoc """
  渠道出站适配器契约。

  统一语义：
  - `send/2` 接收标准消息（Final/Error）。
  - 返回 `:ok` 表示渠道已受理回写。
  - 返回 `{:error, reason}` 表示回写失败（由控制面映射为 `egress_fail`）。
  """

  alias Men.Channels.Egress.Messages.{ErrorMessage, FinalMessage}

  @type message :: FinalMessage.t() | ErrorMessage.t()

  @callback send(target :: map() | term(), message()) :: :ok | {:error, term()}
end
