# Men 项目代码结构与职责完整分析

## 项目一句话定位

**Men** = 多平台 Webhook 网关 + 多运行时桥接框架（GongCLI/GongRPC/ZCPG RPC）

接收钉钉/飞书/企微消息事件 → 验签 + 标准化 → 调度执行 → 超时控制 → 结果回写

## 完整分析导航

本项目包含 4 份详细文档，逐层深入：

| 文档 | 大小 | 内容 | 适合读者 |
|------|------|------|---------|
| [README.md](docs/README.md) | 5.1 KB | 文档导航 + 快速开始 + 依赖清单 | 初次接触者 |
| [QUICK_REFERENCE.md](docs/QUICK_REFERENCE.md) | 6.6 KB | 速查表 + 常见问题 + 扩展清单 | 需要快速查询 |
| [DIAGRAM.txt](docs/DIAGRAM.txt) | 17 KB | ASCII 架构图 + 决策树 + 配置示例 | 视觉学习者 |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | 14 KB | 6 层分层详解 + 数据流 + 代码位置 | 深度学习者 |

## 快速概览

### 代码统计

- **总行数**: 12,199（lib/ 目录，Elixir code）
- **模块数**: 91 个 .ex/.exs 文件
- **技术栈**: Phoenix 1.7.21 + Ecto + Plug
- **支持平台**: 钉钉（DingTalk）、飞书（Feishu）、企微（Qiwei）
- **开发语言**: Elixir
- **统计口径**: `cloc lib --json --quiet`（2026-02-25）

### 架构分层（6 层）

```
Layer 1: HTTP 入口           (MenWeb.Endpoint)
         ↓
Layer 2: 入站验证            (Ingress Adapters)
         ↓
Layer 3: Gateway 主调度       (DispatchServer - GenServer)
         ↓
Layer 4: 运行时桥接          (GongCLI - Port 执行)
         ↓
Layer 5: 出站适配            (Egress Adapters)
         ↓
Layer 6: HTTP 响应           (Webhook Response)
```

### 核心功能

1. **安全验证** (Layer 2)
   - 钉钉: HMAC-SHA256 签名验证
   - 飞书: SHA256 签名 + ETS 重放检测
   - 时间窗检查（可配 300-900 秒）

2. **Gateway 调度** (Layer 3)
   - GenServer L1 单进程状态机
   - 入站事件标准化 + 验证
   - MapSet 去重（run_id）
   - 运行时调用 + 结果回写

3. **运行时执行** (Layer 4)
   - Erlang Port 启动子进程
   - 30 秒超时（可配）
   - 10 并发限制（可配）
   - 进程树清理（pkill + kill）

4. **出站回写** (Layer 5)
   - 统一响应体格式
   - egress 失败允许重试
   - 完整的错误信息回报

### 关键数字

| 指标 | 值 |
|------|-----|
| 默认超时 | 30 秒 |
| 最大并发 | 10 |
| 钉钉时间窗 | 5 分钟 |
| 飞书时间窗 | 5 或 15 分钟 |
| 入站事件字段 | request_id + payload + session_key + run_id + metadata |

## 关键模块查询

### Gateway 层 (核心编排)

```
lib/men/gateway/dispatch_server.ex (1,149 行 code)
├─ dispatch/1        入口函数
├─ normalize_event/1  事件标准化 + 验证
├─ ensure_not_duplicate/1  run_id 去重
├─ do_start_turn/1    调用运行时桥接
├─ do_send_final/1    回写成功结果
├─ do_send_error/1    回写错误信息
└─ mark_processed/1   标记已处理

状态机状态:
  processed_run_ids: MapSet<run_id>           # 已处理集合
  session_last_context: Map<session_key, ctx> # 会话上下文
  bridge_adapter: module()                     # 运行时桥接实现
  egress_adapter: module()                     # 出站适配实现
```

### 运行时桥接 (GongCLI)

```
lib/men/runtime_bridge/gong_cli.ex (381 行 code)
├─ start_turn/2           入口：执行 gong CLI
├─ run_port_command/4     Port 启动 + 等待
├─ acquire_slot/2         并发计数 (+1)
├─ release_slot/0         并发计数 (-1)
├─ await_port_result/4    receive 循环
├─ cleanup_timed_out_port/2  超时清理
└─ timeout 处理流程：
    Port.open() 
    → receive {...after 30000}
    → cleanup_timed_out_port()
       ├ Port.close(port)
       ├ pkill -P <pid> -TERM
       ├ kill -TERM <pid>
       ├ sleep 30ms
       └ kill -KILL <pid>
```

### 入站适配 (验证 + 标准化)

```
钉钉 (DingtalkIngress - 208 行 code)
├─ normalize/1
├─ verify_signature()     HMAC-SHA256(secret, timestamp + body)
├─ verify_timestamp_window()  time(now) - time(header) <= 300s
└─ 字段提取: sender_id, conversation_id, content

飞书 (FeishuIngress - 239 行 code)
├─ normalize/1
├─ verify_signature()     SHA256(timestamp + nonce + secret)
├─ verify_timestamp_window()  300s 或 900s（可配）
├─ replay_detection()     ETS nonce 表查重
└─ 字段提取: 基于 app_id 多机器人配置
```

### 出站适配 (响应映射)

```
钉钉 (DingtalkEgress)
├─ to_webhook_response/1
└─ {200, %{status: "final|timeout|error", code: "...", message: "...", ...}}

飞书 (FeishuEgress)
├─ to_webhook_response/1
└─ {200, %{...}}
```

## 工作流完整示例

### 钉钉消息 → 工作流执行 → 结果回写

```
1. POST /webhooks/dingtalk
   Body: {timestamp, signature, sender_id, conversation_id, content, ...}

2. DingtalkController.callback/2
   └─ DingtalkIngress.normalize(request)
      ├─ verify_signature()  ← HMAC-SHA256 验证
      ├─ verify_timestamp_window()  ← 时间戳检查
      └─ {request_id, payload, session_key, metadata}

3. DispatchServer.dispatch(inbound_event)
   ├─ normalize_event()  ← 检查 request_id, payload
   ├─ ensure_not_duplicate()  ← MapSet.member?(run_id) ?
   ├─ do_start_turn()
   │  └─ GongCLI.start_turn(prompt, context)
   │     ├─ acquire_slot()  ← 检查并发计数 (max=10)
   │     ├─ Port.open({:spawn_executable, "gong"}, args)
   │     │  └─ args: [--prompt JSON, --request-id, --session-key, --run-id]
   │     ├─ await_port_result()  ← receive 循环 (timeout=30s)
   │     │  ├─ 收到 stdout/stderr → 累积到 output
   │     │  ├─ 收到 {:exit_status, 0} → 成功
   │     │  ├─ 收到 {:exit_status, N} → 失败
   │     │  └─ timeout → cleanup_timed_out_port()
   │     └─ release_slot()  ← 并发计数 (-1)
   │
   ├─ do_send_final()
   │  └─ DingtalkEgress.send(session_key, FinalMessage)
   │
   └─ mark_processed(run_id)  ← 记录已处理（egress 失败除外）

4. DingtalkEgress.to_webhook_response(dispatch_result)
   └─ {200, %{
        status: "final",
        code: "OK",
        message: "Generated text...",
        request_id: "req_xxx",
        run_id: "run_xxx",
        details: {...}
      }}

5. HTTP 200 OK ✓
```

## 错误处理决策树

```
dispatch(event)
  ↓
normalize_event() 成功?
  ├─ ✗ → {:error, INVALID_EVENT}
  └─ ✓ ↓
    ensure_not_duplicate() 检查
      ├─ 重复 → {:ok, :duplicate}
      └─ 新的 ↓
        do_start_turn() 执行
          ├─ ✓ → do_send_final()
          │       ├─ ✓ mark_processed() → {:ok, result}
          │       └─ ✗ ← EGRESS_ERROR (NOT 标记，允许重试)
          │
          └─ ✗ → do_send_error()
                  ├─ ✓ mark_processed() → {:error, ...}
                  └─ ✗ ← EGRESS_ERROR (NOT 标记，允许重试)
```

## 配置关键字一览

```elixir
# Gateway 主状态机
config :men, Men.Gateway.DispatchServer,
  bridge_adapter: Men.RuntimeBridge.GongCLI,
  egress_adapter: Men.Channels.Egress.DingtalkAdapter,
  storage_adapter: :memory

# GongCLI 运行时
config :men, Men.RuntimeBridge.GongCLI,
  command: "gong",
  timeout_ms: 30_000,
  max_concurrency: 10,
  backpressure_strategy: :reject,
  prompt_arg: "--prompt",
  request_id_arg: "--request-id",
  session_key_arg: "--session-key",
  run_id_arg: "--run-id"

# 钉钉入站
config :men, Men.Channels.Ingress.DingtalkAdapter,
  secret: {:system, "DINGTALK_WEBHOOK_SECRET"},
  signature_window_seconds: 300

# 飞书入站
config :men, Men.Channels.Ingress.FeishuAdapter,
  bots: %{
    "app_id_1" => "secret_1",
    "app_id_2" => "secret_2"
  },
  signature_window_seconds: 300
```

## 扩展新平台（Slack 示例）

### 检查清单

- [ ] 创建 `lib/men/channels/ingress/slack_adapter.ex`
  - [ ] 实现 `@behaviour Men.Channels.Ingress.Adapter`
  - [ ] 实现 `normalize/1` 回调
  - [ ] 签名验证逻辑
  - [ ] 事件标准化

- [ ] 创建 `lib/men/channels/egress/slack_adapter.ex`
  - [ ] 实现 `@behaviour Men.Channels.Egress.Adapter`
  - [ ] 实现 `send/2` 回调
  - [ ] 实现 `to_webhook_response/1` 回调

- [ ] 创建 `lib/men_web/controllers/webhooks/slack_controller.ex`
  - [ ] 编排 ingress → dispatch → egress

- [ ] 更新 `lib/men_web/router.ex`
  - [ ] 添加 `post "/webhooks/slack", SlackController, :create`

- [ ] 添加配置
  - [ ] `:men, Men.Channels.Ingress.SlackAdapter, [...]`

- [ ] 编写测试
  - [ ] 单元测试（签名、标准化）
  - [ ] 集成测试（E2E）

## 核心概念速记

### Session Key（会话键）

唯一标识一个会话，格式: `{channel}:{user_id}[:g:{group_id}][:t:{thread_id}]`

例子:
- `dingtalk:user_123`
- `feishu:bot_456:g:group_789`
- `slack:channel_999:u:user_111:t:thread_222`

### 追踪 ID（Trace IDs）

三层追踪:
- `request_id` → 唯一标识单次 HTTP 请求
- `session_key` → 唯一标识会话（跨多轮对话）
- `run_id` → 唯一标识单次执行（幂等重试）

### 入站事件（Inbound Event）

统一结构，所有平台适配器的输出:

```elixir
%{
  request_id: "req_abc123",
  payload: %{...},              # 标准化的事件内容
  session_key: "dingtalk:u123",
  run_id: "run_xyz789",         # 可选，未提供时由 dispatcher 生成
  metadata: %{...}              # 可选
}
```

## 文件树完整版

```
lib/
├── men.ex                           # 域逻辑入口
├── men_web.ex                       # Web 层入口
└── men/
    ├── application.ex               # OTP 应用启动
    ├── repo.ex                      # Ecto Repo
    ├── mailer.ex                    # Swoosh 邮件
    ├── gateway/
    │   ├── dispatch_server.ex       # 主状态机 1,149 行 code
    │   └── types.ex                 # 类型定义
    ├── channels/
    │   ├── ingress/
    │   │   ├── adapter.ex           # 接口契约
    │   │   ├── dingtalk_adapter.ex  # 钉钉验签+标准化 208 行 code
    │   │   ├── feishu_adapter.ex    # 飞书验签+标准化+重放 239 行 code
    │   │   ├── qiwei_adapter.ex     # 企微验签+标准化
    │   │   ├── qiwei_idempotency.ex # 企微回调幂等处理
    │   │   └── event.ex             # 事件结构
    │   └── egress/
    │       ├── adapter.ex           # 接口契约
    │       ├── dingtalk_adapter.ex  # 钉钉响应映射
    │       ├── feishu_adapter.ex    # 飞书响应映射
    │       └── messages.ex          # FinalMessage, ErrorMessage
    ├── routing/
    │   └── session_key.ex           # 会话键生成规则
    └── runtime_bridge/
        ├── bridge.ex                # 适配器接口
        ├── gong_cli.ex              # GongCLI 实现 381 行 code
        ├── gong_rpc.ex              # GongRPC 实现
        ├── zcpg_rpc.ex              # ZCPG RPC 实现
        ├── request.ex               # 请求结构
        └── response.ex              # 响应结构

└── men_web/
    ├── router.ex                    # 路由定义
    ├── endpoint.ex                  # Phoenix 端点
    ├── telemetry.ex                 # 遥测
    ├── gettext.ex                   # 国际化
    ├── controllers/
    │   ├── page_controller.ex       # 首页
    │   ├── webhooks/
    │   │   ├── dingtalk_controller.ex    # 钉钉 webhook 编排
    │   │   └── feishu_controller.ex      # 飞书 webhook 编排
    │   └── error_*.ex
    ├── plugs/
    │   └── raw_body_reader.ex       # body 缓存读取器
    ├── cache_body_reader.ex         # body 缓存
    └── components/
        ├── core_components.ex
        └── layouts.ex
```

## 常见问题 (FAQ)

**Q: 同一个 run_id 重复发来会怎样?**
A: DispatchServer 检查 MapSet，若 run_id 已存在返回 `{:ok, :duplicate}`，不再执行。

**Q: 超时后子进程一定被清理掉了吗?**
A: 是。cleanup_timed_out_port() 会执行 pkill + kill -TERM/-KILL，确保进程树被清理。

**Q: 去重存储支持持久化吗?**
A: 目前仅支持内存 MapSet。建议通过注入自定义 storage_adapter 实现 Redis 持久化。

**Q: GongCLI 如何处理超时?**
A: 启动 Task + Port，用外层 Task.yield(task, wait_ms) 守卫，确保清理时间充足。

**Q: 飞书的重放防护如何工作?**
A: ETS 表记录 nonce + TTL，每次请求检查 seen_nonce?，自动清理过期数据。

**Q: 支持哪些消息平台?**
A: 目前支持钉钉和飞书，可扩展为 Slack、Telegram、WeChat 等。

## 下一步扩展方向

1. **存储优化**: Redis 持久化去重
2. **性能**: Oban/Broadway 异步队列
3. **可观测性**: Prometheus 指标暴露
4. **实时性**: WebSocket 客户端推送
5. **批量处理**: 事件聚批执行
6. **审计**: 数据库 + 操作日志

---

**总结**: Men 是一个设计精良的 Webhook 网关框架，分层清晰、职责单一、易于扩展。通过 GenServer 状态机编排、Port 进程隔离、ETS 内存高效，实现了生产级的可靠性和性能。

生成时间: 2026-02-21
