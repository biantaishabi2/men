defmodule Men.Channels.Egress.Adapter do
  @moduledoc """
  渠道出站适配器契约。
  """

  alias Men.Channels.Egress.Messages.{ErrorMessage, EventMessage, FinalMessage}

  @type message :: FinalMessage.t() | ErrorMessage.t() | EventMessage.t()

  @callback send(target :: term(), message()) :: :ok | {:error, term()}
end
