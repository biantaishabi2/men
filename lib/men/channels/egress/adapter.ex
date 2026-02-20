defmodule Men.Channels.Egress.Adapter do
  @moduledoc """
  渠道出站适配器契约。
  """

  alias Men.Channels.Egress.Messages.{ErrorMessage, FinalMessage}

  @type message :: FinalMessage.t() | ErrorMessage.t()

  @callback send(target :: term(), message()) :: :ok | {:error, term()}
end
