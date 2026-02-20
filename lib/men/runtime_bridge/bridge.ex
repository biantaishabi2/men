defmodule Men.RuntimeBridge.Bridge do
  @moduledoc """
  Runtime Bridge 统一契约。
  """

  @type error_type :: :failed | :timeout | :overloaded

  @type error_payload :: %{
          type: error_type(),
          code: binary(),
          message: binary(),
          run_id: binary(),
          request_id: binary(),
          session_key: binary(),
          details: map() | nil
        }

  @type success_payload :: %{
          text: binary(),
          meta: map()
        }

  @typedoc """
  start_turn/2 第二个参数使用的追踪上下文。
  """
  @type turn_context :: %{
          optional(:request_id) => binary(),
          optional(:session_key) => binary(),
          optional(:run_id) => binary()
        }

  @callback start_turn(prompt :: binary(), context :: turn_context()) ::
              {:ok, success_payload()} | {:error, error_payload()}
end
