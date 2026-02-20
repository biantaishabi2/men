# Imported OpenClaw Findings (Cli + Gong)

This file consolidates the architecture findings we already produced in sibling repos,
so `men` starts from a stable seed instead of ad-hoc coding.

## Source Documents

From `Cli`:
- `../Cli/compiler/bcc/examples/openclaw-arch/README.md`
- `../Cli/compiler/bcc/examples/openclaw-arch/V3架构整改分析.md`
- `../Cli/compiler/bcc/examples/openclaw-arch/seed/v3.target-matrix.yaml`
- `../Cli/compiler/bcc/examples/openclaw-arch/seed/v3.transition-matrix.yaml`
- `../Cli/compiler/bcc/examples/openclaw-arch/seed/v3.gates.yaml`

From `gong`:
- `../gong/docs/openclaw-gateway-分析.md`
- `../gong/docs/架构设计.md`

## Imported Conclusions

1. OpenClaw is primarily a multi-channel gateway + control plane, not the runtime itself.
2. Gateway and runtime must be separated by stable contracts (port/adapter), not direct internals.
3. Session key / route identity is the cross-module contract and must live in infra/shared contract area.
4. Use strict target matrix plus temporary transition matrix. Never encode migration debt in target.
5. For this workspace split:
- `gong`: coding-agent runtime engine
- `men`: gateway/control-plane/channel ingress and egress

## Men-Specific Decisions

1. Keep `gong` unchanged as runtime core.
2. Build all Feishu and other channel integration in `men`.
3. Start with `gong` CLI bridge in `men`, then evolve to RPC without changing gateway boundaries.
4. Make Phoenix (`Channel`, `PubSub`, `LiveView`) the gateway surface layer, not runtime layer.

## Anti-Patterns to Avoid (directly from previous analysis)

1. Do not let infra depend on gateway or channel implementations.
2. Do not place common helpers inside ops entry and import them from lower layers.
3. Do not create barrel-style transitive coupling between channel and plugin modules.
4. Do not let external adapter modules import runtime internals.
