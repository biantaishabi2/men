# Qiwei Callback Cutover & Rollback Runbook

## 1. 配置项
- `QIWEI_CALLBACK_ENABLED`：是否启用 callback ingress。
- `QIWEI_CALLBACK_TOKEN`：企微 callback token（验签）。
- `QIWEI_CALLBACK_ENCODING_AES_KEY`：企微 EncodingAESKey（解密）。
- `QIWEI_RECEIVE_ID`：企微 receive_id（通常为 corp_id）。
- `QIWEI_BOT_NAME`：文本兜底匹配 `@bot_name`。
- `QIWEI_BOT_USER_ID`：结构化 @ 列表优先匹配 id。
- `QIWEI_REPLY_REQUIRE_MENTION`：是否仅 @ 命中才回复 XML（默认 `true`）。
- `QIWEI_IDEMPOTENCY_TTL_SECONDS`：幂等 TTL（默认 120s）。
- `QIWEI_CUTOVER_ENABLED`：是否开启 men -> zcpg 分流。
- `QIWEI_CUTOVER_TENANT_WHITELIST`：白名单租户（逗号分隔）。
- `QIWEI_CALLBACK_TIMEOUT_MS`：callback 场景 zcpg 超时。

## 2. 灰度步骤
1. 先保持 `QIWEI_CUTOVER_ENABLED=false`，验证 callback 基础可用。
2. 设置少量租户白名单：
   - `QIWEI_CUTOVER_TENANT_WHITELIST=tenantA`
3. 打开 cutover：
   - `QIWEI_CUTOVER_ENABLED=true`
4. 观察 15 分钟：
   - 401 比例
   - 解密失败率
   - reply 命中率
   - 下游超时率
   - 幂等命中率
5. 白名单按 1% -> 5% -> 20% -> 50% -> 100% 逐步扩容。

## 3. 回滚 SOP（分钟级）
1. 关闭切流：`QIWEI_CUTOVER_ENABLED=false`
2. 清空白名单：`QIWEI_CUTOVER_TENANT_WHITELIST=`
3. 保留 callback ingress：`QIWEI_CALLBACK_ENABLED=true`
4. 验证回滚：
   - callback 接口仍返回 `200 success` 或 reply XML
   - 不再调用 zcpg 路径
   - 业务回包恢复 legacy 语义

## 4. 指标建议
- 安全指标：
  - `401_ratio`（验签/解密失败）
  - `decrypt_failure_ratio`
- 业务指标：
  - `reply_hit_ratio`
  - `downstream_timeout_ratio`
  - `idempotency_hit_ratio`
- 异常告警：
  - 5 分钟窗口 `401_ratio > 5%`
  - 5 分钟窗口 `downstream_timeout_ratio > 5%`

## 5. 示例环境变量
```bash
export QIWEI_CALLBACK_ENABLED=true
export QIWEI_CALLBACK_TOKEN=xxxx
export QIWEI_CALLBACK_ENCODING_AES_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export QIWEI_RECEIVE_ID=ww1234567890
export QIWEI_BOT_NAME=MenBot
export QIWEI_BOT_USER_ID=zhangsan
export QIWEI_REPLY_REQUIRE_MENTION=true
export QIWEI_IDEMPOTENCY_TTL_SECONDS=120
export QIWEI_CALLBACK_TIMEOUT_MS=8000
export QIWEI_CUTOVER_ENABLED=false
export QIWEI_CUTOVER_TENANT_WHITELIST=
```
