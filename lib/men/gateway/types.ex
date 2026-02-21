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

  @typedoc """
  SessionCoordinator 映射条目。
  """
  @type session_mapping_entry :: %{
          required(:session_key) => binary(),
          required(:runtime_session_id) => binary(),
          required(:last_access_at) => integer(),
          required(:expires_at) => integer()
        }

  @typedoc """
  SessionCoordinator 运行配置。
  """
  @type session_coordinator_config :: %{
          required(:enabled) => boolean(),
          required(:ttl_ms) => pos_integer(),
          required(:gc_interval_ms) => pos_integer(),
          required(:max_entries) => pos_integer(),
          required(:invalidation_codes) => [atom() | binary()]
        }

  @typedoc """
  Session 失效原因，用于白名单错误码校验。
  """
  @type session_invalidation_reason ::
          %{required(:session_key) => binary(), required(:code) => atom() | binary()}
          | %{
              required(:runtime_session_id) => binary(),
              required(:code) => atom() | binary()
            }
          | %{
              required(:session_key) => binary(),
              required(:runtime_session_id) => binary(),
              required(:code) => atom() | binary()
            }
end
