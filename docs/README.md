# Men 项目文档

本目录包含 Men 项目的完整代码结构分析和参考文档。

## 文档清单

### 1. [ARCHITECTURE.md](./ARCHITECTURE.md) - 完整架构分析
**内容**: 6 层分层架构详解 + 核心特性 + 数据流示例
- 项目定位与代码统计
- 分层架构（HTTP 入口 → Ingress → Gateway → Runtime Bridge → Egress → 响应）
- 关键特性（去重、超时、安全验证、错误处理）
- 数据流示例（钉钉消息→gong 执行→回写）
- 完整文件树
- 配置示例
- 扩展方向

### 2. [DIAGRAM.txt](./DIAGRAM.txt) - 架构图与决策树
**内容**: ASCII 拓扑图 + 错误处理流程 + 配置注入 + 可观测性
- 6 层架构可视化
- 错误处理决策树
- 配置注入示例
- 全链路追踪 ID 说明

### 3. [QUICK_REFERENCE.md](./QUICK_REFERENCE.md) - 快速参考手册
**内容**: 速查表 + 常见问题 + 扩展检查清单
- 一句话定位
- 核心流程（5 步）
- 关键数字（代码行数、超时值、并发数等）
- 模块职责速查表
- 错误分类表
- 配置关键字
- 常见问题 FAQ
- 新增平台适配检查清单

## 快速导航

### 按场景查询

**我要...** → **看哪个文档**

- 理解项目整体架构 → [ARCHITECTURE.md](./ARCHITECTURE.md)
- 看代码框架图 → [DIAGRAM.txt](./DIAGRAM.txt)
- 快速查找某个配置项 → [QUICK_REFERENCE.md](./QUICK_REFERENCE.md)
- 添加新的消息平台支持 → [QUICK_REFERENCE.md](./QUICK_REFERENCE.md#新增平台适配检查清单)
- 了解错误处理逻辑 → [DIAGRAM.txt](./DIAGRAM.txt#error-handling-decision-tree)
- 理解 GongCLI 执行流程 → [ARCHITECTURE.md](./ARCHITECTURE.md#第-4-层运行时桥接-runtime-bridge)

### 按模块查询

**模块名称** → **查看文档 + 文件位置**

| 模块 | 位置 | 文档 |
|------|------|------|
| DispatchServer | `lib/men/gateway/dispatch_server.ex` | [ARCHITECTURE.md - Layer 3](./ARCHITECTURE.md#第-3-层gateway主调度) |
| GongCLI | `lib/men/runtime_bridge/gong_cli.ex` | [ARCHITECTURE.md - Layer 4](./ARCHITECTURE.md#第-4-层运行时桥接-runtime-bridge) |
| DingtalkIngress | `lib/men/channels/ingress/dingtalk_adapter.ex` | [ARCHITECTURE.md - Layer 2](./ARCHITECTURE.md#第-2-层入站适配-ingress) |
| FeishuIngress | `lib/men/channels/ingress/feishu_adapter.ex` | [ARCHITECTURE.md - Layer 2](./ARCHITECTURE.md#第-2-层入站适配-ingress) |
| DingtalkEgress | `lib/men/channels/egress/dingtalk_adapter.ex` | [ARCHITECTURE.md - Layer 5](./ARCHITECTURE.md#第-5-层出站适配-egress) |
| FeishuEgress | `lib/men/channels/egress/feishu_adapter.ex` | [ARCHITECTURE.md - Layer 5](./ARCHITECTURE.md#第-5-层出站适配-egress) |

## 核心概念

### 入站事件 (Inbound Event)

统一的入站事件结构，所有平台适配器的标准化输出。

```elixir
%{
  request_id: "req_abc123",              # 唯一标识单次 HTTP 请求
  payload: %{...},                       # 标准化后的事件内容
  session_key: "dingtalk:user_123",      # 唯一标识会话
  run_id: "run_xyz789",                  # 唯一标识单次执行（可选）
  metadata: %{...}                       # 额外信息（可选）
}
```

### 会话键 (Session Key)

格式: `{channel}:{user_id}[:g:{group_id}][:t:{thread_id}]`

例如:
- `dingtalk:user_123`
- `feishu:bot_456:g:group_789`
- `feishu:bot_456:g:group_789:t:thread_000`

### 追踪 ID (Trace IDs)

三层追踪体系：
- `request_id` → 单次 HTTP 请求
- `session_key` → 会话（跨多轮对话）
- `run_id` → 单次执行（幂等重试）

## 项目统计

- **总代码行数**: 3,047
- **Elixir 模块数**: 33
- **技术栈**: Phoenix 1.7.21 + Ecto + Plug
- **支持平台**: 钉钉、飞书
- **默认超时**: 30 秒
- **默认并发**: 10

## 依赖项

### 主要依赖

| 依赖 | 版本 | 用途 |
|------|------|------|
| phoenix | ~> 1.7.21 | Web 框架 |
| phoenix_ecto | ~> 4.5 | Ecto 集成 |
| ecto_sql | ~> 3.10 | SQL 适配 |
| postgrex | >= 0.0.0 | PostgreSQL 驱动 |
| phoenix_live_view | ~> 1.0 | 实时视图 |
| swoosh | ~> 1.5 | 邮件发送 |
| finch | ~> 0.13 | HTTP 客户端 |
| jason | ~> 1.2 | JSON 编码/解码 |

### 开发依赖

| 依赖 | 用途 |
|------|------|
| phoenix_live_reload | 热重载 |
| esbuild | JavaScript 打包 |
| tailwind | CSS 框架 |

## 常见操作

### 启动开发服务

```bash
cd /home/wangbo/document/men
mix setup              # 安装依赖 + 创建数据库
mix phx.server        # 启动服务 (localhost:4000)
```

### 测试

```bash
mix test              # 运行所有测试
mix test path/to/test_file.exs  # 运行单个测试
```

### 格式化

```bash
mix format            # 格式化代码
mix format --check-formatted  # 检查格式
```

## 扩展资源

- [Phoenix 文档](https://www.phoenixframework.org/)
- [Elixir 文档](https://elixir-lang.org/)
- [Ecto 文档](https://hexdocs.pm/ecto/)
- [Plug 文档](https://hexdocs.pm/plug/)

## 文档维护

这些文档由代码分析生成，包含：
- 分层架构详解
- 模块职责说明
- 数据流示意
- 配置示例
- 常见问题解答

如有代码变更，建议同步更新相应文档。

---

生成时间: 2026-02-21
