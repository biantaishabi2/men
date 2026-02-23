# men->zcpg Cutover Runbook

## 1. 前置检查
- 确认 `ZCPG_CUTOVER_ENABLED=false`（默认关闭）。
- 确认 `ZCPG_CUTOVER_TENANT_WHITELIST` 为空或仅包含本次灰度租户。
- 确认 zcpg 可用性（5xx、timeout、P95 延迟）满足上线阈值。
- 执行 `mix men.cutover status` 记录当前基线。

## 2. 灰度步骤
1. 设置白名单租户（例如 tenantA）：
   `mix men.cutover whitelist --set tenantA`
2. 打开 cutover：
   `mix men.cutover enable`
3. 验证白名单租户 @消息是否路由 zcpg，非白名单是否仍走 legacy。
4. 按 1->5->20->50->100% 逐步扩容白名单并观察 15 分钟。

## 3. 监控指标与告警阈值
- `[:men, :dispatch, :zcpg, :request]`
  - `status=error` 5 分钟错误率 > 5% 告警。
  - `duration_ms` P95 > 3000ms 告警。
- `[:men, :runtime_bridge, :zcpg_rpc, :request]`
  - `code=timeout` 或 5xx 映射错误持续增长告警。
- 业务指标
  - passive reply 成功率 < 99% 告警。

## 4. 自动回退策略
- zcpg 超时/5xx/transport 错误：单请求立即回退 legacy。
- 熔断器：`5 次失败 / 30s` 开路，`60s` 后半开探测，探测成功恢复。

## 5. 手动回滚
- 一键回滚：`mix men.cutover rollback`
- 或者：
  1. `mix men.cutover disable`
  2. `mix men.cutover whitelist --set ""`
- 回滚后验证：
  - 所有租户均走 legacy。
  - 回复成功率恢复基线。

## 6. 回滚演练
- 触发演练标记：`mix men.cutover drill`
- 演练步骤：
  1. 在测试租户注入 zcpg timeout。
  2. 验证自动回退到 legacy 且继续回包。
  3. 执行 `mix men.cutover rollback`。
  4. 验证全量 legacy 稳定。

## 7. 验收记录模板
- 演练时间：
- 执行人：
- 灰度租户：
- 观测窗口：
- 关键指标：
- 是否触发自动回退：
- 手动回滚耗时：
- 结果与结论：
