## Summary

- 

## Test plan

- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test`

## 验收前置检查

- [ ] 依赖冻结：#37/#38/#39 调用边界通过 runtime adapter 统一封装
- [ ] 契约落盘：Telemetry Contract v1（字段与事件名）已写入文档
- [ ] CI 白名单：smoke 套件已配置且作为 PR 默认门禁
- [ ] full 套件：nightly/手动触发路径可执行
- [ ] feature flag：`jit_enabled/jit_disabled/smoke_mode` 三态均已验证
- [ ] 回放能力：`scripts/jit/replay.sh` 可按 `trace_id/session_id` 复现关键决策链

Closes #
