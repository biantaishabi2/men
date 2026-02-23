# 企微 Callback Cutover/Rollback Runbook

## 1. 配置项
- `QIWEI_CALLBACK_ENABLED`：企微 callback ingress 开关。
- `QIWEI_CALLBACK_TOKEN`：企微 callback 验签 token。
- `QIWEI_CALLBACK_ENCODING_AES_KEY`：企微 callback AES key（43 字符）。
- `QIWEI_CORP_ID`：企微 corp id（用于解密后 receive_id 校验）。
- `QIWEI_BOT_USER_ID`：结构化 @ 判定 bot 用户 id。
- `QIWEI_BOT_NAME`：文本兜底 @ 名称（例如 `men-bot`）。
- `QIWEI_REPLY_REQUIRE_MENTION`：是否要求 @ 才被动回复，默认 `true`。
- `QIWEI_REPLY_MAX_CHARS`：被动回复最大长度，默认 `600`。
- `QIWEI_IDEMPOTENCY_TTL_SECONDS`：幂等窗口，默认 `120` 秒。
- `QIWEI_CALLBACK_TIMEOUT_MS`：callback 链路同步超时，默认 `4000` ms。
- `QIWEI_CUTOVER_ENABLED`：切流开关，控制是否走 zcpg。
- `QIWEI_CUTOVER_TENANT_WHITELIST`：切流租户白名单（逗号分隔）。

## 2. 灰度步骤
1. 发布前确认 `QIWEI_CALLBACK_ENABLED=true`，并完成 token/aes/corp 配置。
2. 将 `QIWEI_CUTOVER_ENABLED=false`，先观察 callback 基础握手与 200 success 稳定性。
3. 设置 `QIWEI_CUTOVER_TENANT_WHITELIST=tenantA`（小流量租户）。
4. 打开 `QIWEI_CUTOVER_ENABLED=true`，观察 15 分钟。
5. 按租户批次扩容白名单。

## 3. 观测指标
- `401 比例`：`/webhooks/qiwei` 返回 401 的占比（主要看验签/解密异常）。
- `解密失败率`：解密失败事件占比。
- `reply 命中率`：text 消息中触发被动回复 XML 的比例。
- `下游超时率`：dispatch/zcpg timeout 或 5xx 占比。
- `幂等命中率`：重复投递命中缓存比例。

## 4. 回滚 SOP（分钟级）
1. 设置 `QIWEI_CUTOVER_ENABLED=false`。
2. 清空 `QIWEI_CUTOVER_TENANT_WHITELIST`。
3. 等待配置热更新（分钟级），验证新请求仅走 legacy。
4. 观察 10 分钟：
- `401 比例` 不异常升高；
- `200 success` 比例恢复；
- 无新 `zcpg` 调用。

## 5. 故障降级语义
- 仅 `验签失败/解密失败` 返回 `401 + {status:error, code:UNAUTHORIZED}`。
- 其它异常（下游 timeout/5xx/未知类型）统一返回 `200 success`，避免企微重试风暴。
