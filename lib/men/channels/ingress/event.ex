defmodule Men.Channels.Ingress.Event do
  @moduledoc """
  统一入站事件结构。
  """

  @enforce_keys [:channel, :user_id, :content, :timestamp]
  defstruct [:channel, :user_id, :group_id, :thread_id, :content, :timestamp, metadata: %{}]

  @type t :: %__MODULE__{
          channel: String.t(),
          user_id: String.t(),
          group_id: String.t() | nil,
          thread_id: String.t() | nil,
          content: String.t(),
          metadata: map(),
          timestamp: DateTime.t()
        }
end
