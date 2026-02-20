# Solum Runtime Notes (for Men/Gong Architecture)

来源：用户提供的 Solum 文案草稿（SOLUM: The bedrock for living AI agents）。
本文件用于把理念映射到 `men + gong` 的可执行架构语义。

## 01 Memory

核心定义：
1. context window 是视图，不是存储。
2. 事件先沉积，再分层压缩（sedimentary memory）。
3. 老数据默认摘要化，需要时可回展开到源事件。
4. 重启后可从上次状态继续，不丢连续性。

分层节奏（草案）：
- L1: 10-min
- L2: hourly
- L3: daily
- L4: weekly
- L5: monthly

对 `men/gong` 的落点：
1. `gong` 负责事件流和记忆压缩执行。
2. `men` 只消费“当前帧视图 + 需要的检索结果”，不直接承担记忆治理。

## 02 Context as HUD

核心定义：
1. context 是 HUD（heads-up display），不是聊天拼接。
2. 每一轮推理是一个 frame（认知帧），输入是“当前状态快照”。
3. agent 输出是 action，不是默认文本回复。

典型 frame 块：
1. time
2. rate / budget
3. pins / objectives
4. subscriptions
5. tools status
6. memory pressure / layer usage
7. inbox events

解释：
1. `context as a frame` = 每轮只看“当前决策快照”。
2. 输入是 inbox/event，不是“用户-助手轮对话”。
3. 对外说话要通过显式 action（例如 `send_message`）。

## 03 Architecture (BEAM / OTP)

核心定义：
1. agent 是常驻进程（GenServer），不是每请求重建。
2. supervision 保证局部崩溃可恢复。
3. tool 调用并发执行，互不阻塞。
4. 支持热更新（hot reload）降低中断成本。

对比“胶水式 server”风险：
1. 状态分散文件多，回收路径复杂。
2. 并发/重入/清理逻辑容易堆补丁。
3. 异常恢复与事件分发容易形成重复胶水。

## 04 Orchestration

核心定义：
1. agents can spawn agents（协调者 + 执行者）。
2. 结果通过消息回流，异步、非阻塞。
3. 每个进程隔离 heap；每个 coder 隔离 worktree。
4. 防止 spawn loop 与 token burn。

边界约束（与当前共识一致）：
1. 多 issue DAG/编排主责在 `Cli`。
2. `men` 内仅保留“网关主链路编排”，不做全局任务编排引擎。

## 05 Early Beta Signal

该文案本质上强调的是：
1. continuity（连续性）
2. control（控制力：热更新/可恢复）
3. scale（并发规模）

这三点与 OTP 的设计目标天然一致。

## 运行语义落地（可执行）

1. 触发机制：event-first + timer-backup
- 主触发：外部事件、订阅变化、工具完成回调
- 辅触发：定时 tick（超时、补偿、健康检查）

2. 认知循环异步回流（定义）
- 工具调用异步发起后立即返回 handle
- agent 不阻塞，继续处理后续 frame
- 工具完成结果作为新事件回到 inbox
- 下一帧基于该结果继续决策

3. 常驻（定义）
- 进程长期存活，按事件推进 frame
- 非“请求来一次，重建一次”

## Men 设计影响

1. `channel_ingress` 提供事件输入，不做 heavy state。
2. `gateway_control_plane` 负责 frame 组装与 action 分发。
3. `agent_runtime_bridge` 负责与 `gong` 交互（CLI now, RPC later）。
4. `channel_egress` 负责 action 的渠道回写。
5. `foundation_infra` 负责幂等、日志、观测、订阅与重试支撑。
