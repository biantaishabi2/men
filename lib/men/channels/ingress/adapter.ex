defmodule Men.Channels.Ingress.Adapter do
  @moduledoc """
  渠道入站适配器契约。
  """

  alias Men.Gateway.Types

  @typedoc """
  入站标准化错误码：
  - `:signature_invalid`：签名/时间窗/重放等鉴权失败。
  - 其他 atom/map：解析或字段校验失败。
  """
  @type normalize_error :: :signature_invalid | term()

  @callback normalize(raw_message :: term()) ::
              {:ok, Types.inbound_event()} | {:error, normalize_error()}
end
