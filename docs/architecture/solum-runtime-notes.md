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

## 补充：控制流与数据流闭环（核心）

### 1. 主状态是控制流，数据流是证据平面

1. 控制流（主状态）：
- 当前目标（goal）
- 当前阶段（phase）
- 约束与策略（constraints/policy）
- 待执行动作（pending actions）
- 等待中的异步句柄（awaiting handles）

2. 数据流（证据平面）：
- 工具输出（tool outputs）
- 调研结果与外部事实（research facts / external state）
- 记忆与历史（memory / history）
- inbox 事件沉积（event log）

结论：控制流决定“下一步做什么”，数据流提供“为什么这样做”。

### 2. 分离但强耦合：数据流会反向塑形控制流

1. 控制流决策必须读取数据流证据。
2. 数据流新增关键证据后，必须允许改写控制流：
- 改目标优先级
- 改阶段推进路径
- 改下一步动作集合

这不是“计划一次写死”，而是证据驱动的动态控制。

### 3. ReAct 闭环在本架构中的定义

1. Reason：基于当前控制流 + 相关数据证据进行推理。
2. Act：调用工具/子 Agent/外部动作。
3. Observe：执行结果异步回流并写入数据流。
4. Control Update：用新证据更新控制流。
5. 下一轮 Reason：在更新后的控制流上继续决策。

核心不是“持续输出文本”，而是“持续更新可执行控制状态”。

### 4. OTP 落地语义（主 Agent + 子 Agent）

1. 主 Agent（GenServer）持有控制流，作为单一真相源。
2. 子 Agent/工具异步执行（cast/task），不阻塞主循环。
3. 结果通过消息回流主 Agent inbox（`handle_info`）。
4. 主 Agent 先更新数据流，再按唤醒策略判断是否触发 LLM 推理。
5. 不是每个事件都触发推理：允许“仅落库，不唤醒认知”。

### 5. 两层唤醒（必须区分）

1. 进程唤醒（OTP 层）：
- 收到消息即被调度执行。

2. 推理唤醒（认知层）：
- 是否调用 LLM 由策略决定（优先级、预算、节流、事件类型）。

因此可以做到：事件高频、推理低频；系统保持连续但不滥用模型调用。

### 6. 与 transcript-only 传统模式的本质区别

1. 传统模式把控制流与数据流混在“历史上下文”里。
2. 本模式把控制流抽成主状态，把数据流作为可检索证据平面。
3. 结果是：
- 控制逻辑更稳定、可解释、可调试
- 数据规模更易扩展
- 异步并发与容错更符合 OTP 天然能力

## 补充：分子链（断键补全）认知模型

### 1. 概念定义

该模型用于描述“知道部分信息，但关键连接缺失”的任务状态。

1. 节点（Node）：事实、结论、约束、假设。
2. 键（Bond/Edge）：节点之间的因果、依赖、冲突、证据关系。
3. 断键（Broken Bond）：关键关系缺失，导致无法从目标稳定推导到可执行动作。

重点：问题常常不在“缺一个事实点”，而在“缺一条关键连接关系”。

### 2. 与 ReAct 的关系

1. ReAct 更适合执行阶段（路径较清晰时）。
2. 分子链模型更适合探索阶段（路径不清晰时）。
3. 顺序上通常是：
- 先补断键（探索/调研）
- 再按 ReAct 执行（实施/交付）

### 3. 任务意图驱动（Intent-first）

系统先判定任务目的，再选择行为模式，而非默认直接 ReAct。

1. `investigate`
- 目的：补断键、降低不确定性
- 输出：缺口清单、证据链、置信度变化

2. `plan`
- 目的：在现有图谱上收敛路径
- 输出：候选方案、依赖顺序、里程碑

3. `execute`
- 目的：在高置信度路径上推进交付
- 输出：实现结果、测试结果、验收结论

### 4. 最小落地结构（可直接实现）

```elixir
%TaskGraph{
  nodes: %{node_id => %{type: :fact | :constraint | :hypothesis, content: binary()}},
  edges: [%{from: node_id, to: node_id, rel: :causes | :depends_on | :supports | :conflicts, confidence: float()}],
  broken_bonds: [%{from: node_id, to: node_id, reason: binary(), blocking: boolean()}],
  mode: :investigate | :plan | :execute
}
```

### 5. 模式切换规则（建议）

1. 存在 `blocking=true` 的断键：
- 禁止进入 `execute`
- 维持 `investigate` 或 `plan`

2. 关键路径边置信度达到阈值（例如 `>= 0.75`）：
- 可从 `investigate/plan` 切到 `execute`

3. 执行过程中出现新断键：
- 立即降级回 `investigate`
- 补全后再恢复执行

### 6. 对 men/gong 的实现建议

1. 控制流中新增：
- `mode`（investigate/plan/execute）
- `blocking_gaps`（阻塞断键集合）

2. 数据流中新增：
- `task_graph`（节点、边、断键、置信度）
- `evidence_log`（每次补链的证据来源）

3. 认知唤醒策略新增：
- `investigate`：优先触发“证据采样与验证”
- `execute`：优先触发“动作执行与结果回写”

## 补充：三阶段数学模型与可编排字段

### 1. execute 阶段：有向无环图（DAG）

适用：实施与交付。

1. 节点：可执行任务（task）。
2. 边：依赖关系（`blocked_by`）。
3. 约束：必须无环，才能拓扑排序执行。

最小字段：
- `task_id`
- `blocked_by: [task_id]`
- `status: queued|running|done|failed`

这就是你现在多 issue DAG 的数学基础。

### 2. plan 阶段：AND-OR 图（方案选择图）

适用：路径不唯一但目标明确。

1. OR 节点：可选方案（A 或 B 或 C）。
2. AND 节点：方案内必须同时完成的子目标。
3. 输出：选择一条可行方案，再编译为 execute-DAG。

最小字段：
- `goal_id`
- `alternatives: [plan_option_id]`（OR）
- `requires: [subgoal_id]`（AND）
- `score`（成本/风险/收益综合分）
- `selected: true|false`

### 3. research 阶段：证据图（不确定性图）

适用：知道自己不知道，需要补断键。

1. 节点：命题/假设/事实。
2. 边：支持、冲突、因果、依赖。
3. 每个命题带置信度，目标是降低不确定性、补关键断键。
4. 研究过程中图允许动态变化：节点可增删、边可重连、阻塞关系可重算。

最小字段：
- `claim_id`
- `confidence: 0.0..1.0`
- `supports: [claim_id]`
- `conflicts: [claim_id]`
- `missing_links: [link_id]`（断键）
- `blocking: true|false`

### 4. 统一落地：工具可消费的图节点协议

为便于自动化工具统一处理，建议三阶段节点都具备统一外壳字段：

```yaml
id: string
mode: research|plan|execute
title: string
status: queued|running|done|failed
blocked_by: [id]           # execute 必填，plan/research 可选
depends_on_evidence: [id]  # research/plan 常用
produces: [id]             # 本节点产出（证据/决策/任务）
confidence: 0.0-1.0        # research/plan 使用
priority: int
```

这样你可以做到：
1. `research` 节点产出证据后，自动解除 `plan` 节点阻塞。
2. `plan` 节点选路后，自动生成 `execute` DAG（含 `blocked_by`）。
3. `execute` 失败时，自动回退生成新的 `research` 节点补断键。

### 5. 编排切换规则（可自动化）

1. `research -> plan`
- 关键断键 `blocking=false`，且关键命题 `confidence >= threshold`。

2. `plan -> execute`
- 存在 `selected=true` 的方案，且该方案子目标可编译为无环依赖图。

3. `execute -> research`（回退）
- 节点失败原因为“前提不成立/信息不足/外部状态变化”。
- 自动创建 `research` 节点并回填 `depends_on_evidence`。

### 6. research 图动态更新规则（必须支持）

1. 节点变化：
- 新证据揭示新命题时，允许新增节点。
- 旧命题被证伪时，允许降权或删除节点。

2. 边变化：
- 支持关系可变为冲突关系（`supports -> conflicts`）。
- 依赖关系可重定向（原链路失效后改道）。

3. 阻塞变化：
- 断键补全后，自动解除相关 `blocking_for`。
- 新断键出现时，允许重新阻塞下游节点。

结论：research 不是“静态图求解”，而是“事件驱动的增量重算”。

### 7. research -> plan 的稳定性判据（建议）

除基础阈值外，建议增加“图稳定”约束，避免过早切换：

1. `blocking_gaps == 0`（无关键阻塞断键）。
2. 关键命题 `confidence >= threshold`（例如 `0.70`）。
3. 最近 N 轮（建议 2~3 轮）图结构变化率低于阈值（例如 `< 5%`）。

仅当以上条件同时满足时，才从 `research` 切换到 `plan`。

## 补充：JIT Orchestration（运行时编译控制流）

### 1. 命名与定义

`JIT Orchestration` 指在运行时根据当前状态和回流证据，动态生成与调整下一段控制流，
而不是在开始前一次性固定全量流程。

可理解为：
1. AOT（预编排）：先算完整 DAG，再按图执行。
2. JIT（运行时编排）：执行中持续重算“下一步最优控制动作”。

### 2. 核心闭环（运行时自编排）

1. 判定任务意图（research/plan/execute）。
2. 更新图状态并写入 REPL（任务图、证据图、阻塞关系、置信度）。
3. 提取控制摘要（control summary）注入系统提示词。
4. 由模型给出下一动作（action）。
5. 动作执行后，数据流回流更新图状态。
6. 重新编译下一段控制流（JIT 重算）。

这不是“先有完整脚本再执行”，而是“边执行边编排”。

### 3. 自指挥（Self-Orchestration）语义

主 Agent 具备“指挥自己”的能力：
1. 自己维护长期控制流状态（phase/goal/policy/mode）。
2. 自己把运行事实写入“脑内状态”（REPL/状态存储）。
3. 自己基于新证据调整控制策略与执行路径。

因此控制流不是短事务，而是可持续演化的长期状态机。

### 4. 最小可落地接口（建议）

```yaml
runtime_state:
  mode: research|plan|execute
  control_state:
    goal: string
    phase: string
    policy: map
  graph_state:
    task_graph_ref: string
    evidence_graph_ref: string
  control_summary:
    text: string
    version: int
  compile_tick:
    last_recompiled_at: int
    reason: event|timer|failure_recovery
```

说明：
1. `control_summary` 作为系统提示词片段注入，不直接塞全量数据。
2. `graph_state` 保持结构化全量状态，按需检索。
3. `compile_tick` 记录每次 JIT 重算的触发原因，便于审计与调试。

## 补充：控制流/数据流分离的 OTP 工程落地（聚焦版）

本节不讨论三模式细节，仅定义“控制流与数据流如何分离并通信”。

### 1. 状态归属（强约束）

1. `ControlAgent`（GenServer）只持有控制流：
- goal / phase / policy / pending_actions / in_flight_refs

2. `ReplStore`（GenServer + ETS）只持有数据流：
- tool outputs / research results / external events / shared vars / history

约束：
1. `ControlAgent` 不保存大体量数据（避免数据流侵入控制流）。
2. `ReplStore` 不做控制决策（避免决策逻辑分散）。

### 2. 消息协议（闭环）

1. 主 Agent 委托执行：
- `GenServer.cast(child_pid, {:run_task, task_ref, task_spec})`

2. 子 Agent 回流结果：
- `send(control_pid, {:task_done, task_ref, result_ref})`

3. 主 Agent 回流处理顺序（固定）：
- 先写数据流：`ReplStore.put_result(task_ref, payload)`  
- 再读帧摘要：`ReplStore.build_frame(agent_id)`  
- 再更新控制流：`update_control_state(frame)`  
- 最后决定是否继续委托下一动作

### 3. Frame 作为控制输入（不是全量上下文）

`ControlAgent` 每轮只读取 `frame summary`，不直接拼接全量历史：

```elixir
%{
  facts: [...],
  pending: [...],
  signals: %{errors: ..., budgets: ..., subscriptions: ...},
  version: 123
}
```

意义：
1. 数据流保持完整但不污染控制提示。
2. 控制流只消费决策必需信息。

### 4. 监督树建议

1. `ReplStore` 与 `ControlAgent` 并列常驻。
2. 子 Agent 放入 `DynamicSupervisor`，失败隔离。
3. 主 Agent 崩溃后可重建控制流；数据流由 `ReplStore` 保持连续。

### 5. 一句话原则

控制流 = 一个决策 GenServer。  
数据流 = 一个共享状态服务。  
两者只通过“消息 + frame 摘要”交互，不直接共享内部可变状态。
