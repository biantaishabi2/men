defmodule Men.Channels.Ingress.Adapter do
  @moduledoc """
  渠道入站适配器契约。
  """

  alias Men.Channels.Ingress.Event

  @callback normalize(raw_message :: term()) :: {:ok, Event.t()} | {:error, term()}
end
