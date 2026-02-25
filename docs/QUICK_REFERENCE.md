# Men 项目快速参考

## 一句话定位

**Men** = 多平台 Webhook Gateway + 多运行时桥接框架（GongCLI/GongRPC/ZCPG RPC）

## 核心流程（5 步）

```
1. HTTP 入站
   POST /webhooks/{dingtalk|feishu|qiwei}
   ↓
2. 入站验证（Ingress）
   签名校验 + 时间窗检查 + 重放防护 → 标准化事件
   ↓
3. Gateway 调度（DispatchServer）
   事件标准化 + 去重检查 + 运行时调用 + 结果回写
   ↓
4. 运行时执行（Runtime Bridge）
   GongCLI/GongRPC/ZCPG RPC + 超时控制 + 并发限制 + 清理机制
   ↓
5. 出站回写（Egress）
   结果 → 渠道发送接口（钉钉/飞书）
```

## 关键数字

| 指标 | 值 |
|------|-----|
| 总代码行数（lib/，Elixir code） | 12,199 |
| Elixir 文件数（.ex/.exs） | 91 |
| 超时默认值 | 30 秒 |
| 最大并发数 | 10 |
| 时间窗（钉钉） | 5 分钟 |
| 支持平台 | 钉钉、飞书、企微 |

统计口径：`cloc lib --json --quiet`（2026-02-25）

## 模块职责速查

| 模块 | 职责 |
|------|------|
| `MenWeb.Endpoint` | HTTP 服务启动 + Plug 配置 |
| `DingtalkController` | 钉钉 webhook 入口，编排 ingress→dispatch→egress |
| `FeishuController` | 飞书 webhook 入口，编排 ingress→dispatch→egress |
| `DingtalkIngress` | 钉钉签名验证（HMAC-SHA256）+ 事件标准化 |
| `FeishuIngress` | 飞书签名验证（SHA256）+ 重放检测（ETS）+ 事件标准化 |
| `DispatchServer` | GenServer L1 主状态机，编排 bridge→egress |
| `GongCLI` | Port 子进程执行，超时/并发控制，进程清理 |
| `DingtalkEgress` | 结果发送到钉钉（支持 webhook / app_robot） |
| `FeishuEgress` | 结果映射为飞书 webhook 响应 |
| `SessionKey` | 会话键生成规则 |

## 错误分类

| 错误类型 | Code | 说明 | 是否标记已处理 |
|---------|------|------|----------------|
| Invalid Signature | INVALID_SIGNATURE | 签名校验失败 | ✓ |
| Timestamp Expired | SIGNATURE_EXPIRED | 时间戳过期 | ✓ |
| CLI Timeout | CLI_TIMEOUT | 执行超时 | ✓ |
| CLI Exit Non-Zero | CLI_EXIT_N | 执行失败（exit code N） | ✓ |
| Overloaded | CLI_OVERLOADED | 并发超限 | ✓ |
| Egress Error | EGRESS_ERROR | 回写失败 | ✗（允许重试） |

## 配置关键字

```elixir
# Gateway
:men, Men.Gateway.DispatchServer,
  bridge_adapter: ...    # 运行时桥接实现
  egress_adapter: ...    # 出站适配实现
  storage_adapter: ...   # 去重存储（内存/Redis）

# GongCLI
:men, Men.RuntimeBridge.GongCLI,
  command: "gong"        # 可执行程序路径或名称
  timeout_ms: 30_000     # 超时时间（毫秒）
  max_concurrency: 10    # 最大并发数
  prompt_arg: "--prompt" # 参数名
  request_id_arg: "--request-id"
  session_key_arg: "--session-key"
  run_id_arg: "--run-id"

# 钉钉
:men, Men.Channels.Ingress.DingtalkAdapter,
  secret: {:system, "DINGTALK_WEBHOOK_SECRET"}
  signature_window_seconds: 300

# 飞书
:men, Men.Channels.Ingress.FeishuAdapter,
  bots: %{
    "app_id_1" => "secret_1",
    "app_id_2" => "secret_2"
  }
  signature_window_seconds: 300
```

### 钉钉出站适配模式

`Men.Channels.Egress.DingtalkRobotAdapter` 支持两种模式：

1. `webhook`（默认兼容模式）
   - 环境变量：`DINGTALK_ROBOT_WEBHOOK_URL`、`DINGTALK_ROBOT_SECRET`、`DINGTALK_ROBOT_SIGN_ENABLED`
2. `app_robot`（robotCode 模式）
   - 环境变量：`DINGTALK_ROBOT_MODE=app_robot`
   - 必填：`DINGTALK_ROBOT_CODE`、`DINGTALK_APP_KEY`、`DINGTALK_APP_SECRET`
   - 可选：`DINGTALK_TOKEN_URL`、`DINGTALK_ROBOT_OTO_SEND_URL`

## 运行时依赖

- **Erlang Port**: 启动子进程 (`gong` 命令)
- **ETS**: 并发计数 + 飞书重放检测
- **PostgreSQL**: Repo（配置但未使用）
- **Swoosh**: 邮件（配置但未使用）

## 已处理去重机制

- **存储**: 内存 MapSet（`processed_run_ids`）
- **范围**: 单进程 DispatchServer 生命周期
- **重启丢失**: ✓ 需持久化建议使用 Redis
- **幂等保障**: 同 `run_id` 不重复执行（egress 失败除外）

## 全链路追踪 ID

```
request_id   → 唯一标识单次 HTTP 请求
session_key  → 唯一标识会话（channel:user_id[:g:group_id][:t:thread_id]）
run_id       → 唯一标识单次执行（幂等重试）
```

## 超时处理流程

```
1. 启动 Port 子进程执行 gong CLI
2. receive {...after timeout_ms} 等待输出
3. 超时触发 → cleanup_timed_out_port()
   a) Port.close(port)
   b) pkill -P <os_pid> -TERM   (终止直接子进程)
   c) kill -TERM <os_pid>        (SIGTERM 主进程)
   d) sleep 30ms
   e) kill -KILL <os_pid>        (SIGKILL 强制杀进程)
4. 返回 {:timeout, output, cleanup_result}
```

## GongCLI 参数传递示例

```bash
# Elixir 调用
gong \
  --prompt '{"content":"用户消息","channel":"dingtalk"}' \
  --request-id 'req_abc123' \
  --session-key 'dingtalk:user_456:g:group_789' \
  --run-id 'run_xyz'

# gong 应收到 stdin
$STDIN = '{"content":"用户消息","channel":"dingtalk"}'

# gong 应输出到 stdout
Generate result text...
# 以及 exit code
0  ← success
1  ← failure
```

## 新增平台适配检查清单

- [ ] 实现 `*.Ingress.SlackAdapter` 
  - [ ] `normalize/1` → 验签 + 标准化
  - [ ] 实现 `@behaviour Men.Channels.Ingress.Adapter`
  
- [ ] 实现 `*.Egress.SlackAdapter`
  - [ ] `send/2` → 发送消息
  - [ ] `to_webhook_response/1` → 映射响应
  - [ ] 实现 `@behaviour Men.Channels.Egress.Adapter`
  
- [ ] 新增 Controller
  - [ ] `MenWeb.Webhooks.SlackController`
  - [ ] 编排 ingress → dispatch → egress
  
- [ ] 更新 Router
  - [ ] `POST /webhooks/slack`
  
- [ ] 添加配置
  - [ ] `:men, Men.Channels.Ingress.SlackAdapter, [...]`
  
- [ ] 编写测试
  - [ ] 签名验证测试
  - [ ] 事件标准化测试
  - [ ] 端到端集成测试

## 常见问题

### Q1: run_id 重复时会发生什么？
A: DispatchServer 检查 `MapSet.member?(run_id)`，若已存在返回 `{:ok, :duplicate}`，不再执行。

### Q2: 超时后子进程是否确保被清理？
A: 是。`cleanup_timed_out_port()` 会执行 `pkill -P <pid>` + `kill -TERM/KILL`，确保进程树被清理。

### Q3: 支持持久化去重吗？
A: 目前仅支持内存。建议通过配置注入自定义 `storage_adapter` 实现 Redis 持久化。

### Q4: 飞书重放防护如何工作？
A: ETS 表记录 nonce + TTL，每次请求检查 `seen_nonce?`。ETS 自动清理过期数据。

### Q5: GongCLI 超时的默认值是多少？
A: 30 秒（可配置 `timeout_ms`）。

## 代码入口

```elixir
# 启动
lib/men/application.ex
  {Men.Gateway.DispatchServer, []}

# HTTP 路由
lib/men_web/router.ex
  post "/webhooks/dingtalk", DingtalkController, :callback
  post "/webhooks/feishu", FeishuController, :create

# 主调度逻辑
lib/men/gateway/dispatch_server.ex
  def dispatch(server, inbound_event)

# 运行时执行
lib/men/runtime_bridge/gong_cli.ex
  def start_turn(prompt, context)
```

## 扩展思路

1. **存储层**: Redis → 分布式去重
2. **队列**: Oban/Broadway → 异步处理 + 重试策略
3. **可观测**: Prometheus → 性能指标 + 告警
4. **实时推送**: WebSocket → 客户端进度更新
5. **插件系统**: 动态加载 Ingress/Egress 适配器
6. **审计日志**: 数据库 + 时间戳 + 操作者追踪
