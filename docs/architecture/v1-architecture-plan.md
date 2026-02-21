# Men V1 Architecture Plan

## Big Modules

1. `gateway_control_plane`
- owns protocol, routing, session lookup, dispatch decisions

2. `channel_ingress`
- owns webhook/http/ws inbound adapters (Feishu first)

3. `channel_egress`
- owns outbound rendering and channel delivery

4. `agent_runtime_bridge`
- owns bridge contract to `gong` (CLI now, RPC later)

5. `plugin_tool_extension`
- owns gateway-level plugins/actions/hooks (kept minimal in V1)

6. `foundation_infra`
- owns config, telemetry, persistence, idempotency, shared contracts

7. `ops_client_entry`
- owns LiveView admin, ops endpoints, manual control tools

8. `external_dependencies`
- owns third-party SDK wrappers and external adapter ports

## Submodule Layout (first cut)

1. `gateway_control_plane`
- `protocol`
- `routing`
- `session_registry`
- `dispatch`

2. `channel_ingress`
- `feishu`
- `webhook_verifier`
- `inbound_decoder`

3. `channel_egress`
- `renderers`
- `delivery`
- `retry`

4. `agent_runtime_bridge`
- `contracts`
- `gong_cli` (V1: Port 子进程模式，向后兼容)
- `gong_rpc` (V2: Erlang 分布式 RPC，常驻节点模式)
- `node_connector` (节点连接管理、自动重连)
- `event_adapter`

5. `foundation_infra`
- `config`
- `storage`
- `telemetry`
- `security`
- `idempotency`

## Adapter Contracts (must keep stable)

1. `channel_ingress` implements `IngressAdapter`
- owns webhook/auth/signature/decode for each channel

2. `channel_egress` implements `EgressAdapter`
- owns rendering + delivery for each channel

3. `agent_runtime_bridge` implements `RuntimeBridge`
- owns all calls to `gong` (CLI or distributed RPC, configurable)
- V1: `gong_cli` — Port 子进程模式（每次请求启动新 BEAM VM）
- V2: `gong_rpc` — Erlang 分布式节点 RPC（Gong 作为常驻 BEAM 节点，:rpc.call 直接调用）
- other modules must not import `gong` internals directly

## Integration Contract with Gong

V1 contract (CLI mode):
1. create or resolve session key
2. send prompt to `gong` via Port.open
3. collect stdout as response
4. persist status and correlation ids

V2 contract (distributed RPC mode):
1. Node.connect to gong node (auto-reconnect via node_connector)
2. :rpc.call Gong.SessionManager.create_session → get session pid
3. :rpc.call Gong.Session.prompt → submit prompt
4. Gong.Session.subscribe → receive {:session_event, event} asynchronously
5. stream events back to egress in real-time
6. :rpc.call Gong.Session.close → cleanup

Contract rule:
- `men` only calls bridge contract (`agent_runtime_bridge`), never imports `gong` internals.
- bridge adapter is configurable: GongCLI (V1) or GongRPC (V2), switch via config.

## Why OTP First (architecture rationale)

This gateway is not a simple request-response app. The core path is:
`Ingress -> Route/Session -> Dispatch -> RuntimeBridge -> Egress`,
and it is event-driven, long-lived, and async by nature.

When this is implemented with ad-hoc server glue, common issues grow quickly:
1. scattered state machines across files
2. re-entrancy / race cleanup logic
3. manual retry/recovery and lifecycle guards
4. event fan-out and subscriber leak risk

For `men`, we prefer OTP-native structure:
1. `GenServer` for session/run state ownership
2. `Task.Supervisor` for async tool/runtime work
3. `Phoenix.PubSub` for event distribution
4. supervision tree for restart/recovery guarantees

This keeps channel adapters thin and keeps control-plane logic stable while scaling
from single-channel to multi-channel integrations.

## Runtime Semantics (Frame Model)

1. `context as a frame`
- each inference cycle consumes a HUD-like state frame, not full chat transcript replay
- frame includes: inbox events, tool states, subscriptions, limits, memory pressure

2. `event-first + timer-backup`
- event triggers are primary (webhook, subscription change, tool completion)
- timer ticks are backup (timeout check, retry, health sweep)

3. `async cognitive loop`
- tool calls are async and return immediately
- runtime keeps progressing without blocking
- tool result re-enters inbox and is processed in next frame

4. `resident process model`
- agent/session loop should be long-lived process state
- avoid per-request reconstruction of runtime state

## Initial Implementation Sequence

1. scaffold module directories and behaviours
2. implement Feishu webhook verify + dedupe in `channel_ingress`
3. implement `agent_runtime_bridge.gong_cli`
4. implement gateway dispatch happy path
5. implement minimal outbound ack + completion callback
6. add integration test for full flow
