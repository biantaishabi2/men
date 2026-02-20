defmodule Men.Gateway.Types do
  @moduledoc """
  Gateway Dispatch 协议类型定义。
  """

  @typedoc """
  入站事件统一结构。

  - `session_key` 可选，未提供时由 `channel/user_id/group_id/thread_id` 推导。
  - `run_id` 可选，未提供时由调度器生成。
  - `metadata` 可选，默认 `%{}`。
  """
  @type inbound_event :: %{
          required(:request_id) => binary(),
          required(:payload) => term(),
          optional(:session_key) => binary(),
          optional(:run_id) => binary(),
          optional(:metadata) => map(),
          optional(:channel) => binary() | atom(),
          optional(:user_id) => binary() | atom() | integer(),
          optional(:group_id) => binary() | atom() | integer(),
          optional(:thread_id) => binary() | atom() | integer()
        }

  @typedoc """
  单次运行上下文。
  """
  @type run_context :: %{
          required(:session_key) => binary(),
          required(:run_id) => binary(),
          required(:request_id) => binary(),
          required(:payload) => term(),
          required(:metadata) => map()
        }

  @typedoc """
  Dispatch 成功结果。
  """
  @type dispatch_result :: %{
          required(:session_key) => binary(),
          required(:run_id) => binary(),
          required(:request_id) => binary(),
          required(:payload) => map(),
          required(:metadata) => map()
        }

  @typedoc """
  Dispatch 错误结果。
  """
  @type error_result :: %{
          required(:session_key) => binary(),
          required(:run_id) => binary(),
          required(:request_id) => binary(),
          required(:reason) => binary(),
          optional(:code) => binary() | nil,
          required(:metadata) => map()
        }
end
