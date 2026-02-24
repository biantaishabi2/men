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
          optional(:mode_signals) => map(),
          optional(:channel) => binary() | atom(),
          optional(:user_id) => binary() | atom() | integer(),
          optional(:group_id) => binary() | atom() | integer(),
          optional(:thread_id) => binary() | atom() | integer()
        }

  @typedoc """
  事件 actor 身份：ACL 判定使用。
  """
  @type actor :: %{
          required(:role) => :main | :child | :tool | :system,
          required(:session_key) => binary(),
          optional(:agent_id) => binary(),
          optional(:tool_id) => binary()
        }

  @typedoc """
  事件信封策略（Ops Policy 下发）。
  """
  @type policy :: %{
          required(:acl) => map(),
          required(:wake) => map(),
          required(:dedup_ttl_ms) => pos_integer(),
          required(:version) => non_neg_integer(),
          required(:policy_version) => binary()
        }

  @typedoc """
  网关事件信封规范。
  """
  @type envelope :: %{
          required(:type) => binary(),
          required(:source) => binary(),
          required(:session_key) => binary(),
          required(:event_id) => binary(),
          required(:version) => non_neg_integer(),
          required(:ets_keys) => [binary()],
          required(:payload) => map(),
          optional(:wake) => boolean() | nil,
          optional(:inbox_only) => boolean() | nil,
          optional(:target) => binary() | nil,
          optional(:ts) => integer(),
          optional(:meta) => map()
        }

  @typedoc """
  单次运行上下文（最小归属信息）。
  """
  @type run_context :: %{
          required(:run_id) => binary(),
          required(:session_key) => binary(),
          required(:runtime_session_id) => binary(),
          required(:attempt) => pos_integer()
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
