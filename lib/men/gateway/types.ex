defmodule Men.Gateway.Types do
  @moduledoc """
  Gateway MVP 主链路协议类型定义。
  """

  @typedoc """
  入站事件统一结构。

  - `request_id`：入站请求唯一标识。
  - `payload`：桥接侧可消费的内容（通常为文本或结构化 map）。
  - `channel`：渠道标识（`"feishu"` / `"dingtalk"`）。
  - `event_type`：渠道事件类型（如 `message`）。
  - `session_key`：可选，未提供时由 `channel/user_id/group_id/thread_id` 推导。
  - `run_id`：可选，未提供时由桥接层生成。
  - `metadata`：可选，默认 `%{}`，用于透传 reply token 等渠道字段。
  """
  @type inbound_event :: %{
          required(:request_id) => binary(),
          required(:payload) => term(),
          required(:channel) => binary(),
          required(:event_type) => binary(),
          required(:user_id) => binary() | atom() | integer(),
          optional(:group_id) => binary() | atom() | integer() | nil,
          optional(:thread_id) => binary() | atom() | integer() | nil,
          optional(:session_key) => binary() | nil,
          optional(:run_id) => binary() | nil,
          optional(:metadata) => map() | nil,
          optional(:raw) => map() | nil
        }

  @typedoc """
  路由决策最小结构。
  """
  @type route_result :: %{
          required(:session_key) => binary(),
          required(:channel) => binary(),
          required(:event_type) => binary(),
          required(:target) => term()
        }

  @typedoc """
  Bridge 成功结构。
  """
  @type bridge_ok_result :: %{
          required(:status) => :ok,
          required(:run_id) => binary(),
          required(:text) => binary(),
          optional(:meta) => map()
        }

  @typedoc """
  Bridge 超时结构。
  """
  @type bridge_timeout_result :: %{
          required(:status) => :timeout,
          required(:run_id) => binary(),
          required(:reason) => binary(),
          optional(:meta) => map()
        }

  @typedoc """
  Bridge 错误结构。
  """
  @type bridge_error_result :: %{
          required(:status) => :error,
          required(:run_id) => binary(),
          required(:reason) => binary(),
          optional(:meta) => map()
        }

  @typedoc """
  Bridge 统一返回结构。
  """
  @type bridge_result :: bridge_ok_result() | bridge_timeout_result() | bridge_error_result()

  @typedoc """
  运行上下文（dispatch 过程中的标准化上下文）。
  """
  @type run_context :: %{
          required(:request_id) => binary(),
          required(:channel) => binary(),
          required(:event_type) => binary(),
          required(:session_key) => binary(),
          required(:run_id) => binary(),
          required(:payload) => term(),
          required(:metadata) => map(),
          optional(:user_id) => binary() | atom() | integer(),
          optional(:group_id) => binary() | atom() | integer() | nil,
          optional(:thread_id) => binary() | atom() | integer() | nil
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
