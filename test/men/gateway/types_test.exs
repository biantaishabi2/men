defmodule Men.Gateway.TypesTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.Types

  test "at 任务流转合法且终态后禁止返回非终态" do
    assert :ok == Types.validate_task_transition(:pending, :ready)
    assert :ok == Types.validate_task_transition(:ready, :running)
    assert :ok == Types.validate_task_transition(:running, :succeeded)

    assert {:error, %{code: "TASK_INVALID_TRANSITION"}} =
             Types.validate_task_transition(:succeeded, :running)
  end

  test "同 task_id 或同作用域 idempotency_key 命中时返回幂等命中" do
    task = %{
      task_id: "task-1",
      idempotency_key: "order-1001",
      idempotency_scope: "tenant-a",
      schedule_type: :at,
      max_retries: 2,
      timeout_ms: 30_000
    }

    assert Types.idempotent_hit?(task, %{task_id: "task-1"})

    assert Types.idempotent_hit?(task, %{
             task_id: "task-another",
             idempotency_key: "order-1001",
             idempotency_scope: "tenant-a"
           })

    assert {:ok, %{idempotent_hit: true, task: ^task}} =
             Types.resolve_idempotent_request(task, %{
               task_id: "task-1",
               schedule_type: :at,
               max_retries: 2,
               timeout_ms: 30_000
             })
  end

  test "幂等命中但关键字段冲突时返回 TASK_DUPLICATE" do
    task = %{
      task_id: "task-1",
      schedule_type: :at,
      scheduled_at: ~U[2026-02-25 03:42:00Z],
      max_retries: 2,
      timeout_ms: 30_000
    }

    assert {:error,
            %{
              code: "TASK_DUPLICATE",
              conflict_fields: [:timeout_ms]
            }} =
             Types.resolve_idempotent_request(task, %{
               task_id: "task-1",
               schedule_type: :at,
               scheduled_at: ~U[2026-02-25 03:42:00Z],
               max_retries: 2,
               timeout_ms: 10_000
             })
  end

  test "超时与执行失败都可重试且重试耗尽后落 TASK_RETRY_EXHAUSTED" do
    assert Types.retryable_error_code?("TASK_TIMEOUT")
    assert Types.retryable_error_code?("TASK_EXECUTION_FAILED")
    refute Types.retryable_error_code?("TASK_INVALID_TRANSITION")

    assert Types.max_attempts(2) == 3
    assert Types.retry_exhausted?(3, 2)

    assert Types.final_failure_code(3, 2, "TASK_TIMEOUT") == "TASK_RETRY_EXHAUSTED"
    assert Types.final_failure_code(3, 2, "TASK_EXECUTION_FAILED") == "TASK_RETRY_EXHAUSTED"
  end

  test "running 可取消并进入终态" do
    assert :ok == Types.validate_task_transition(:running, :cancelled)
    assert Types.terminal_task_state?(:cancelled)
  end
end
