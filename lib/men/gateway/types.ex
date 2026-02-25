defmodule Men.Gateway.Types do
  @moduledoc """
  Gateway Dispatch 协议类型定义。
  """

  @task_states [:pending, :ready, :running, :succeeded, :failed, :cancelled]
  @terminal_task_states [:succeeded, :failed, :cancelled]
  @valid_task_transitions MapSet.new([
                            {:pending, :ready},
                            {:ready, :running},
                            {:running, :succeeded},
                            {:running, :failed},
                            {:running, :ready},
                            {:pending, :cancelled},
                            {:ready, :cancelled},
                            {:running, :cancelled}
                          ])

  @task_schedule_types [:at, :cron]
  @retryable_error_codes MapSet.new(["TASK_TIMEOUT", "TASK_EXECUTION_FAILED"])

  @idempotency_critical_fields [
    :schedule_type,
    :scheduled_at,
    :cron_expr,
    :timezone,
    :timeout_ms,
    :max_retries
  ]

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

  @typedoc """
  任务调度类型。

  - `:at`：一次性触发
  - `:cron`：周期触发（`daily` 在入口归一为 `:cron`）
  """
  @type task_schedule_type :: :at | :cron

  @typedoc """
  任务状态。终态为 `:succeeded | :failed | :cancelled`。
  """
  @type task_state :: :pending | :ready | :running | :succeeded | :failed | :cancelled

  @typedoc """
  任务契约错误码。
  """
  @type task_error_code :: binary()

  @typedoc """
  任务快照契约。
  """
  @type task_snapshot :: %{
          required(:task_id) => binary(),
          required(:schedule_type) => task_schedule_type(),
          optional(:scheduled_at) => DateTime.t() | nil,
          optional(:cron_expr) => binary() | nil,
          optional(:timezone) => binary() | nil,
          optional(:next_run_at) => DateTime.t() | nil,
          optional(:last_run_at) => DateTime.t() | nil,
          optional(:schedule_id) => binary() | nil,
          optional(:fire_time) => DateTime.t() | nil,
          required(:state) => task_state(),
          required(:attempt) => pos_integer(),
          required(:max_retries) => non_neg_integer(),
          required(:timeout_ms) => pos_integer(),
          optional(:idempotency_key) => binary() | nil,
          optional(:last_error_code) => task_error_code() | nil,
          optional(:last_error_reason) => binary() | nil,
          required(:created_at) => DateTime.t(),
          required(:updated_at) => DateTime.t(),
          optional(:started_at) => DateTime.t() | nil,
          optional(:finished_at) => DateTime.t() | nil
        }

  @typedoc """
  任务状态事件载荷契约。
  """
  @type task_state_event_payload :: %{
          required(:task_id) => binary(),
          required(:from_state) => task_state(),
          required(:to_state) => task_state(),
          required(:occurred_at) => binary(),
          optional(:schedule_id) => binary(),
          optional(:fire_time) => binary(),
          optional(:attempt) => pos_integer(),
          optional(:reason_code) => binary(),
          optional(:reason_message) => binary(),
          optional(:idempotent_hit) => boolean()
        }

  @typedoc """
  创建任务的幂等请求视图。
  """
  @type task_idempotency_request :: %{
          required(:task_id) => binary(),
          optional(:idempotency_key) => binary() | nil,
          optional(:idempotency_scope) => binary() | nil
        }

  @typedoc """
  幂等冲突错误结构。
  """
  @type task_duplicate_error :: %{
          required(:code) => binary(),
          required(:reason) => binary(),
          required(:conflict_fields) => [atom()],
          required(:task) => task_snapshot()
        }

  @spec task_schedule_types() :: [task_schedule_type()]
  def task_schedule_types, do: @task_schedule_types

  @spec normalize_task_schedule_type(term()) :: {:ok, task_schedule_type()} | {:error, term()}
  def normalize_task_schedule_type(:at), do: {:ok, :at}
  def normalize_task_schedule_type(:cron), do: {:ok, :cron}
  def normalize_task_schedule_type(:daily), do: {:ok, :cron}
  def normalize_task_schedule_type("at"), do: {:ok, :at}
  def normalize_task_schedule_type("cron"), do: {:ok, :cron}
  def normalize_task_schedule_type("daily"), do: {:ok, :cron}

  def normalize_task_schedule_type(_),
    do: {:error, %{code: "TASK_INVALID_SCHEDULE", field: :schedule_type}}

  @spec validate_task_schedule(map()) :: :ok | {:error, %{code: binary(), field: atom()}}
  def validate_task_schedule(task) when is_map(task) do
    with {:ok, schedule_type} <- normalize_task_schedule_type(Map.get(task, :schedule_type)),
         :ok <- validate_schedule_required_fields(schedule_type, task),
         :ok <- validate_schedule_optional_fields(task) do
      :ok
    end
  end

  def validate_task_schedule(_), do: {:error, %{code: "TASK_INVALID_SCHEDULE", field: :task}}

  @spec task_states() :: [task_state()]
  def task_states, do: @task_states

  @spec terminal_task_states() :: [task_state()]
  def terminal_task_states, do: @terminal_task_states

  @spec terminal_task_state?(task_state() | term()) :: boolean()
  def terminal_task_state?(state), do: state in @terminal_task_states

  @spec valid_task_transition?(task_state() | term(), task_state() | term()) :: boolean()
  def valid_task_transition?(from_state, to_state) do
    MapSet.member?(@valid_task_transitions, {from_state, to_state})
  end

  @spec validate_task_transition(task_state() | term(), task_state() | term()) ::
          :ok
          | {:error,
             %{
               code: binary(),
               from_state: task_state() | term(),
               to_state: task_state() | term()
             }}
  def validate_task_transition(from_state, to_state) do
    if valid_task_transition?(from_state, to_state) do
      :ok
    else
      {:error,
       %{
         code: "TASK_INVALID_TRANSITION",
         from_state: from_state,
         to_state: to_state
       }}
    end
  end

  @spec max_attempts(non_neg_integer()) :: pos_integer()
  def max_attempts(max_retries) when is_integer(max_retries) and max_retries >= 0 do
    1 + max_retries
  end

  @spec retry_exhausted?(pos_integer(), non_neg_integer()) :: boolean()
  def retry_exhausted?(attempt, max_retries)
      when is_integer(attempt) and attempt >= 1 and is_integer(max_retries) and max_retries >= 0 do
    attempt >= max_attempts(max_retries)
  end

  @spec retryable_error_code?(binary() | term()) :: boolean()
  def retryable_error_code?(code) when is_binary(code),
    do: MapSet.member?(@retryable_error_codes, code)

  def retryable_error_code?(_), do: false

  @spec final_failure_code(pos_integer(), non_neg_integer(), binary() | nil) :: binary() | nil
  def final_failure_code(attempt, max_retries, reason_code)
      when is_integer(attempt) and attempt >= 1 and is_integer(max_retries) and max_retries >= 0 do
    if retryable_error_code?(reason_code) and retry_exhausted?(attempt, max_retries) do
      "TASK_RETRY_EXHAUSTED"
    else
      reason_code
    end
  end

  @spec idempotent_hit?(task_snapshot() | map(), task_idempotency_request() | map()) :: boolean()
  def idempotent_hit?(existing_task, request) when is_map(existing_task) and is_map(request) do
    same_task_id?(existing_task, request) or same_scoped_idempotency_key?(existing_task, request)
  end

  @spec resolve_idempotent_request(task_snapshot() | map(), map(), keyword()) ::
          {:ok, %{idempotent_hit: false}}
          | {:ok, %{task: task_snapshot() | map(), idempotent_hit: true}}
          | {:error, task_duplicate_error()}
  def resolve_idempotent_request(existing_task, request, opts \\ [])
      when is_map(existing_task) and is_map(request) do
    if idempotent_hit?(existing_task, request) do
      critical_fields = Keyword.get(opts, :critical_fields, @idempotency_critical_fields)

      conflict_fields =
        critical_fields
        |> Enum.filter(&Map.has_key?(request, &1))
        |> Enum.reject(&(Map.get(existing_task, &1) == Map.get(request, &1)))

      if conflict_fields == [] do
        {:ok, %{task: existing_task, idempotent_hit: true}}
      else
        {:error,
         %{
           code: "TASK_DUPLICATE",
           reason: "idempotency key matched but critical fields conflicted",
           conflict_fields: conflict_fields,
           task: existing_task
         }}
      end
    else
      {:ok, %{idempotent_hit: false}}
    end
  end

  defp same_task_id?(existing_task, request) do
    existing_task_id = Map.get(existing_task, :task_id)
    request_task_id = Map.get(request, :task_id)
    is_binary(existing_task_id) and existing_task_id != "" and existing_task_id == request_task_id
  end

  defp same_scoped_idempotency_key?(existing_task, request) do
    existing_key = Map.get(existing_task, :idempotency_key)
    request_key = Map.get(request, :idempotency_key)

    existing_scope = Map.get(existing_task, :idempotency_scope)
    request_scope = Map.get(request, :idempotency_scope)

    is_binary(existing_key) and existing_key != "" and existing_key == request_key and
      existing_scope == request_scope
  end

  defp validate_schedule_required_fields(:at, task) do
    require_datetime_field(task, :scheduled_at)
  end

  defp validate_schedule_required_fields(:cron, task) do
    with :ok <- require_text_field(task, :cron_expr),
         :ok <- require_text_field(task, :timezone),
         :ok <- require_datetime_field(task, :next_run_at) do
      :ok
    end
  end

  defp validate_schedule_optional_fields(task) do
    with :ok <- validate_optional_datetime(task, :scheduled_at),
         :ok <- validate_optional_datetime(task, :next_run_at),
         :ok <- validate_optional_datetime(task, :last_run_at),
         :ok <- validate_optional_datetime(task, :fire_time) do
      :ok
    end
  end

  defp require_text_field(task, field) do
    case Map.get(task, field) do
      value when is_binary(value) ->
        if byte_size(String.trim(value)) > 0 do
          :ok
        else
          {:error, %{code: "TASK_INVALID_SCHEDULE", field: field}}
        end

      _ ->
        {:error, %{code: "TASK_INVALID_SCHEDULE", field: field}}
    end
  end

  defp require_datetime_field(task, field) do
    case Map.get(task, field) do
      nil ->
        {:error, %{code: "TASK_INVALID_SCHEDULE", field: field}}

      value ->
        value
        |> normalize_datetime_field()
        |> case do
          {:ok, _} -> :ok
          :error -> {:error, %{code: "TASK_INVALID_SCHEDULE", field: field}}
        end
    end
  end

  defp validate_optional_datetime(task, field) do
    task
    |> Map.get(field)
    |> normalize_datetime_field()
    |> case do
      {:ok, _} -> :ok
      :error -> {:error, %{code: "TASK_INVALID_SCHEDULE", field: field}}
    end
  end

  defp normalize_datetime_field(nil), do: {:ok, nil}
  defp normalize_datetime_field(%DateTime{} = dt), do: {:ok, dt}

  defp normalize_datetime_field(value) when is_binary(value) do
    with {:ok, dt, 0} <- DateTime.from_iso8601(String.trim(value)) do
      {:ok, dt}
    else
      _ -> :error
    end
  end

  defp normalize_datetime_field(_), do: :error
end
