# Men 项目代码结构与职责分析

## 项目定位

**Men** 是一个 **Gateway + Webhook 集成框架**，用于接收来自多个消息平台（钉钉、飞书、企微）的事件，经过运行时执行（GongCLI/GongRPC/ZCPG RPC），再将结果回写到对应的平台。

核心职责：**入站验证 → 运行时桥接 → 出站适配**

---

## 代码统计

- **总代码行数（lib/，Elixir code）**: 12,199 行
- **核心模块数**: 91 个 `.ex/.exs` 文件
- **技术栈**: Phoenix 1.7.21 + Ecto + Plug
- **统计口径**: `cloc lib --json --quiet`（2026-02-25）

---

## 项目架构（分层）

### 第 1 层：API 入口 (MenWeb)
**职责**: HTTP 请求解析与路由

```
lib/men_web/
├── router.ex                          # 路由定义
│   └── POST /webhooks/dingtalk        → DingtalkController.callback
│   └── POST /webhooks/feishu          → FeishuController.create
│   └── GET/POST /webhooks/qiwei       → QiweiController.verify/callback
├── controllers/
│   ├── webhooks/dingtalk_controller.ex    # 钉钉 webhook 处理
│   ├── webhooks/feishu_controller.ex      # 飞书 webhook 处理
│   ├── webhooks/qiwei_controller.ex       # 企微 callback 处理
│   └── page_controller.ex
├── plugs/
│   └── raw_body_reader.ex             # 缓存原始 body（用于签名验证）
├── cache_body_reader.ex               # Body 缓存读取器
└── endpoint.ex                        # Phoenix 端点配置
```

**特殊设计**：
- `CacheBodyReader` 缓存请求体，方便后续签名验证（避免 stream 读取一次后失效）

---

### 第 2 层：入站适配 (Ingress)
**职责**: 从 webhook 原始数据解析→验签→时间窗检查→事件标准化

```
lib/men/channels/ingress/
├── adapter.ex                         # 适配器接口契约
├── dingtalk_adapter.ex               # 钉钉入站
│   ├─ verify_signature()              # HMAC-SHA256 签名验证
│   ├─ verify_timestamp_window()       # 时间戳有效期检查（默认 5 min）
│   └─ normalize()                     # 提取关键字段→标准化 inbound_event
├── feishu_adapter.ex                 # 飞书入站
│   ├─ verify_signature()              # 飞书签名机制（支持 strict 和 compat 模式）
│   ├─ replay detection (ETS)          # 基于 nonce 的重放检测（ETS 表缓存）
│   └─ normalize()
└── event.ex                          # 标准化后的事件结构
```

**验证特性**：
- **钉钉**: 
  - 签名算法：`HMAC-SHA256(secret, timestamp + "\n" + body)`
  - 时间窗：可配置（默认 300 秒）
- **飞书**:
  - 签名算法：`SHA256(timestamp + nonce + secret)`
  - 重放防护：ETS 内存表记录 nonce + TTL
  - 两种模式：strict（300s）、compat（900s）

---

### 第 3 层：Gateway（主调度）
**职责**: 编排 入站 → 运行时桥接 → 出站

```
lib/men/gateway/
├── dispatch_server.ex                # GenServer 状态机，核心编排
│   ├─ normalize_event()              # 验证入站事件完整性
│   ├─ ensure_not_duplicate()         # 基于 run_id 去重（MapSet 记录已处理）
│   ├─ do_start_turn()                # 调用运行时桥接执行
│   ├─ do_send_final()                # 成功结果回写
│   ├─ do_send_error()                # 错误回写
│   └─ state: {bridge_adapter, egress_adapter, processed_run_ids, session_last_context}
└── types.ex                          # 协议类型定义
    ├─ inbound_event                  # 统一入站结构
    ├─ run_context                    # 执行上下文
    ├─ dispatch_result                # 成功结果
    └─ error_result                   # 错误结果
```

**核心流程**:
1. 接收 `inbound_event`（入站事件）
2. 标准化 + 验证（检查必填字段）
3. 去重检查（`run_id` 已处理过吗？）
4. 调用 `bridge_adapter.start_turn()` 执行运行时逻辑
5. 根据结果调用 `egress_adapter.send()` 回写
6. 标记为已处理（egress 失败除外，允许重试）

**错误处理逻辑**:
- 若 egress 失败，**不记录为已处理**，允许同 `run_id` 重试
- 其他错误则标记为已处理，防止重复执行

---

### 第 4 层：运行时桥接 (Runtime Bridge)
**职责**: 调用实际执行器（Gong Agent 引擎），处理超时/并发控制

```
lib/men/runtime_bridge/
├── bridge.ex                         # 适配器接口契约
│   ├─ call/2                         # 基础请求/响应契约
│   └─ start_turn/2                   # 统一语义
├── gong_cli.ex                       # V1: GongCLI 实现（Port 子进程）
│   ├─ run_port_command()             # Port 启动子进程
│   ├─ acquire_slot() / release_slot()# 并发控制（ETS 计数器）
│   ├─ await_port_result()            # 处理输出、退出码、超时
│   └─ cleanup_timed_out_port()       # 超时清理（kill -TERM/-KILL）
├── gong_rpc.ex                       # V2: GongRPC 实现（分布式 Erlang RPC）
│   ├─ start_turn/2                   # :rpc.call 调用 Gong 节点
│   ├─ create_session()               # Gong.SessionManager.create_session
│   ├─ await_completion()             # subscribe + 等待事件完成
│   └─ 配置项:
│       ├─ gong_node (Gong 节点名)
│       ├─ gong_cookie (共享 cookie)
│       └─ rpc_timeout_ms (默认 30s)
├── node_connector.ex                 # 节点连接管理（自动重连）
├── request.ex                        # 请求结构
└── response.ex                       # 响应结构
```

**GongCLI (V1) 执行细节**:
- **启动方式**: `Port.open({:spawn_executable, ...})` + args
- **参数**: `--prompt <json>` `--request-id <id>` `--session-key <key>` `--run-id <id>`
- **超时处理**:
  - 内层 `receive...after` 循环监听 Port 输出
  - 外层 `Task.yield()` 守卫，确保清理完成
  - 超时时执行 `pkill -P <pid> -TERM`（终止子进程），再 `kill -TERM/-KILL` 主进程
- **并发控制**: ETS 计数表，`max_concurrency=10` 时达到上限 → 返回 `{:error, :overloaded}`

**GongRPC (V2) 执行细节**:
- **调用方式**: `:rpc.call(gong_node, Gong.SessionManager, :create_session, [opts])`
- **事件流**: `Gong.Session.subscribe(pid, self())` → 异步接收 `{:session_event, event}`
- **优势**: 零冷启动（Gong 常驻节点）、原生 Erlang term 传递、支持实时事件流
- **连接管理**: `node_connector` 负责 `Node.connect`、断线重连、健康检查

---

### 第 5 层：出站适配 (Egress)
**职责**: 将执行结果映射为平台 API 响应

```
lib/men/channels/egress/
├── adapter.ex                        # 适配器接口契约
├── dingtalk_adapter.ex              # 钉钉出站（无真实 API 调用，仅响应体映射）
│   └─ to_webhook_response()          # 结果 → webhook 响应体
├── feishu_adapter.ex                # 飞书出站
│   └─ to_webhook_response()
└── messages.ex                      # 消息结构
    ├─ FinalMessage                  # 最终消息
    └─ ErrorMessage                  # 错误消息
```

**响应体规范**（钉钉示例）:
```json
{
  "status": "final|timeout|error",
  "code": "OK|CLI_TIMEOUT|DISPATCH_ERROR",
  "message": "text content or error reason",
  "request_id": "...",
  "run_id": "...",
  "details": { ... }
}
```

---

### 第 6 层：辅助模块

#### 会话键生成 (Routing)
```
lib/men/routing/session_key.ex
- 规则: {channel}:{user_id}[:g:{group_id}][:t:{thread_id}]
- 字符集限制: [a-zA-Z0-9_-]+
- 用途: 唯一标识会话（跨渠道、用户、群组、线程）
```

#### 数据库与邮件
```
lib/men/repo.ex                    # Ecto Repo（连接 PostgreSQL）
lib/men/mailer.ex                  # Swoosh 邮件发送（配置但未使用）
```

#### Web 基础设施
```
lib/men_web/
├── components/
│   ├── core_components.ex          # Phoenix 通用组件
│   └── layouts.ex
├── gettext.ex                      # 国际化
└── telemetry.ex                    # 遥测上报
```

---

## 关键特性

### 1. Gateway 核心（L1 主状态机）

在 `lib/men/application.ex` 中启动：
```elixir
{Men.Gateway.DispatchServer, []}
```

- **并发**: GenServer 单进程，消息队列 handle_call，同步处理
- **去重**: 内存 MapSet 记录已处理 `run_id`（重启丢失）
- **会话追踪**: 字典 `session_last_context` 保存最后一次执行上下文

### 2. 运行时执行

**关键约束**：
- 每个 CLI 执行最多持续 30 秒（可配置）
- 最多 10 个并发执行（可配置）
- 超过限制 → 返回 `overloaded` 错误
- 超时 → 清理子进程后返回 `timeout` 错误

### 3. 签名验证 & 安全

**钉钉**:
- 从环境变量 `DINGTALK_WEBHOOK_SECRET` 或配置读取密钥
- 使用 `Plug.Crypto.secure_compare()` 防时序攻击

**飞书**:
- 支持多个 Bot 独立配置（基于 `app_id`）
- ETS 表防重放（持久化需自实现后端）

### 4. 错误处理

分类错误类型：
- `failed`: 执行失败（非零退出码）
- `timeout`: 执行超时
- `overloaded`: 并发超限

**恢复逻辑**:
- egress 失败 → 不标记已处理 → 允许重试同 `run_id`
- 其他错误 → 标记已处理 → 防止重复执行

---

## 数据流示例

### 钉钉用户消息 → 回写响应

```
1. POST /webhooks/dingtalk
   ├─ DingtalkController.callback()
   ├─ DingtalkIngress.normalize()
   │  ├─ verify_signature()  ✓ HMAC-SHA256
   │  ├─ verify_timestamp_window()  ✓ 5 min window
   │  └─ extract: request_id, session_key, payload, metadata
   │
   ├─ DispatchServer.dispatch(inbound_event)
   │  ├─ normalize_event()  ✓ validate request_id, payload
   │  ├─ ensure_not_duplicate()  ✓ check run_id
   │  ├─ do_start_turn()
   │  │  └─ bridge_adapter.start_turn(prompt, context)
   │  │     ├─ [GongCLI] Port.open → await_port_result → cleanup
   │  │     └─ [GongRPC] :rpc.call(gong_node, ...) → subscribe → await events
   │  │
   │  ├─ do_send_final()
   │  │  └─ DingtalkEgress.send(session_key, FinalMessage)
   │  │
   │  └─ mark_processed(run_id)  ✓ unless egress error
   │
   └─ DingtalkEgress.to_webhook_response({:ok|:error, result})
      └─ 200 OK + JSON body
```

---

## 文件树（完整）

```
lib/
├── men.ex                              # 域逻辑入口（暂无内容）
├── men/
│   ├── application.ex                 # OTP 应用启动（启动 DispatchServer）
│   ├── repo.ex                         # Ecto Repo
│   ├── mailer.ex                       # Swoosh 邮件
│   ├── gateway/
│   │   ├── dispatch_server.ex         # L1 主状态机
│   │   └── types.ex                   # 协议类型
│   ├── channels/
│   │   ├── ingress/
│   │   │   ├── adapter.ex             # 接口
│   │   │   ├── dingtalk_adapter.ex    # 钉钉验签+标准化
│   │   │   ├── feishu_adapter.ex      # 飞书验签+标准化+重放防护
│   │   │   └── event.ex               # 事件结构
│   │   └── egress/
│   │       ├── adapter.ex             # 接口
│   │       ├── dingtalk_adapter.ex    # 钉钉响应映射
│   │       ├── feishu_adapter.ex      # 飞书响应映射
│   │       └── messages.ex            # FinalMessage, ErrorMessage
│   ├── routing/
│   │   └── session_key.ex             # 会话键生成规则
│   └── runtime_bridge/
│       ├── bridge.ex                  # 适配器接口
│       ├── gong_cli.ex               # V1: GongCLI Port 执行
│       ├── gong_rpc.ex               # V2: GongRPC 分布式 Erlang RPC
│       ├── node_connector.ex          # 节点连接管理（自动重连）
│       ├── request.ex                 # 请求结构
│       └── response.ex                # 响应结构
├── men_web.ex                         # MenWeb 入口
└── men_web/
    ├── router.ex                      # 路由
    ├── endpoint.ex                    # Phoenix 端点
    ├── telemetry.ex                   # 遥测
    ├── gettext.ex                     # 国际化
    ├── controllers/
    │   ├── page_controller.ex         # 首页
    │   ├── page_html.ex
    │   ├── error_html.ex              # 错误页面
    │   ├── error_json.ex              # JSON 错误
    │   └── webhooks/
    │       ├── dingtalk_controller.ex # 钉钉 webhook 入口
    │       └── feishu_controller.ex   # 飞书 webhook 入口
    ├── plugs/
    │   └── raw_body_reader.ex         # Raw body 缓存读取器
    ├── cache_body_reader.ex           # Body 缓存
    ├── components/
    │   ├── core_components.ex
    │   └── layouts.ex
```

---

## 配置示例

```elixir
# config/config.exs

config :men, Men.Gateway.DispatchServer,
  bridge_adapter: Men.RuntimeBridge.GongCLI,
  egress_adapter: Men.Channels.Egress.DingtalkAdapter,
  storage_adapter: :memory

## V1: CLI 模式
config :men, Men.RuntimeBridge.GongCLI,
  command: "gong",
  timeout_ms: 30_000,
  max_concurrency: 10,
  backpressure_strategy: :reject,
  prompt_arg: "--prompt",
  request_id_arg: "--request-id",
  session_key_arg: "--session-key",
  run_id_arg: "--run-id"

## V2: 分布式 RPC 模式
# config :men, Men.Gateway.DispatchServer,
#   bridge_adapter: Men.RuntimeBridge.GongRPC
#
# config :men, Men.RuntimeBridge.GongRPC,
#   gong_node: :"gong@hostname",
#   gong_cookie: "gong_secret",
#   rpc_timeout_ms: 30_000

config :men, Men.Channels.Ingress.DingtalkAdapter,
  secret: {:system, "DINGTALK_WEBHOOK_SECRET"},
  signature_window_seconds: 300

config :men, Men.Channels.Ingress.FeishuAdapter,
  bots: %{
    "bot_id_1" => "bot_secret_1",
    "bot_id_2" => "bot_secret_2"
  },
  signature_window_seconds: 300
```

---

## 总结

**Men 的定位**：
- **类型**: 事件网关 + 运行时适配层
- **核心功能**: 聚合多平台 webhook → 统一执行框架 → 平台无关回写
- **适用场景**: 
  - 接收钉钉/飞书消息，触发 gong 工作流
  - 工作流执行结果回写到消息平台
  - 可扩展为其他平台适配（Slack、Telegram 等）

**技术亮点**:
1. **分层设计** (ingress → gateway → egress)，易于扩展新平台
2. **运行时隔离** (Port + Task 并发控制 + 超时清理)
3. **安全验证** (HMAC-SHA256/SHA256 签名 + 时间窗 + 重放防护)
4. **错误恢复** (egress 失败允许重试)
5. **可观测性** (request_id/session_key/run_id 全链路追踪)

**下一步扩展方向**:
- [ ] GongRPC 适配器 — 替换 CLI 子进程为分布式 Erlang RPC（#21）
- [ ] 添加 Slack 适配器
- [ ] 实现持久化去重（Redis）
- [ ] 添加审计日志（数据库）
- [ ] 实时事件流推送（基于 GongRPC 的 Session.subscribe）
- [ ] 批量事件处理（性能优化）
