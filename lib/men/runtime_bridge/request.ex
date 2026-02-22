defmodule Men.RuntimeBridge.Request do
  @moduledoc """
  RuntimeBridge v1 统一请求模型。
  """

  @enforce_keys [:runtime_id]
  defstruct [:runtime_id, :session_id, :payload, opts: %{}, timeout_ms: nil]

  @type t :: %__MODULE__{
          runtime_id: String.t(),
          session_id: String.t() | nil,
          payload: term() | nil,
          opts: map(),
          timeout_ms: pos_integer() | nil
        }
end
