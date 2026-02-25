# Men 任务调度契约速查

本页是 sub(#67) 契约速查。后续涉及任务调度的子 issue 必须引用本页与 `docs/ARCHITECTURE.md` 的契约章节。

## 状态机速查

- 状态：`pending | ready | running | succeeded | failed | cancelled`
- 终态：`succeeded | failed | cancelled`
- 合法转移：
  - `pending -> ready`
  - `ready -> running`
  - `running -> succeeded`
  - `running -> failed`
  - `running -> ready`（可重试）
  - `pending|ready|running -> cancelled`
- 非法转移统一错误码：`TASK_INVALID_TRANSITION`

## attempt 速查

- `attempt` 从 `1` 开始，表示当前第几次执行尝试
- `max_retries` 是“最大额外重试次数”
- `max_attempts = 1 + max_retries`
- 当 `attempt >= max_attempts` 且错误属于可重试错误（`TASK_TIMEOUT` / `TASK_EXECUTION_FAILED`）时：
  - 任务进入 `failed`
  - `last_error_code = TASK_RETRY_EXHAUSTED`

## 错误码速查

| 错误码 | 含义 |
|---|---|
| `TASK_INVALID_TRANSITION` | 非法状态转移 |
| `TASK_TIMEOUT` | 调度层 start_to_close 超时 |
| `TASK_EXECUTION_FAILED` | RuntimeBridge 业务执行失败 |
| `TASK_RETRY_EXHAUSTED` | 可重试错误达到上限后耗尽 |
| `TASK_DUPLICATE` | 幂等命中但关键字段冲突 |

## 示例载荷

### 创建任务请求（at）

```json
{
  "task_id": "task_20260225_0001",
  "schedule_type": "at",
  "scheduled_at": "2026-02-25T12:00:00Z",
  "timeout_ms": 30000,
  "max_retries": 2,
  "idempotency_key": "order_1001",
  "idempotency_scope": "tenant_a",
  "payload": {
    "channel": "dingtalk",
    "request_id": "req-1"
  }
}
```

### 状态事件（running -> failed）

```json
{
  "type": "task_state_changed",
  "source": "gateway.scheduler",
  "session_key": "scheduler:default",
  "event_id": "evt_task_1",
  "payload": {
    "task_id": "task_20260225_0001",
    "from_state": "running",
    "to_state": "failed",
    "occurred_at": "2026-02-25T12:00:30Z",
    "attempt": 3,
    "reason_code": "TASK_RETRY_EXHAUSTED",
    "reason_message": "start_to_close timeout exhausted retries",
    "idempotent_hit": false
  }
}
```

### 幂等命中响应（不重复创建）

```json
{
  "idempotent_hit": true,
  "task": {
    "task_id": "task_20260225_0001",
    "schedule_type": "at",
    "state": "ready",
    "attempt": 1,
    "max_retries": 2,
    "timeout_ms": 30000,
    "idempotency_key": "order_1001",
    "last_error_code": null,
    "last_error_reason": null,
    "created_at": "2026-02-25T11:59:58Z",
    "updated_at": "2026-02-25T11:59:58Z",
    "started_at": null,
    "finished_at": null
  }
}
```

