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
- `gong_cli`
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
- owns all calls to `gong` (CLI now, RPC later)
- other modules must not import `gong` internals directly

## Integration Contract with Gong

V1 contract (minimum):
1. create or resolve session key
2. send prompt to `gong`
3. stream events back to egress
4. persist status and correlation ids

Contract rule:
- `men` only calls bridge contract (`agent_runtime_bridge`), never imports `gong` internals.

## Initial Implementation Sequence

1. scaffold module directories and behaviours
2. implement Feishu webhook verify + dedupe in `channel_ingress`
3. implement `agent_runtime_bridge.gong_cli`
4. implement gateway dispatch happy path
5. implement minimal outbound ack + completion callback
6. add integration test for full flow
