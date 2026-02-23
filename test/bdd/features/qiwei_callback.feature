Feature: men 企微 callback ingress + passive reply
  为了安全承接 zcpg#5 迁移
  作为 men callback 维护者
  我需要在企微 callback 下保证协议正确、失败降级与可回滚

  Scenario: GET 握手成功
    Given callback 已启用且 token/aes 配置正确
    When 发送合法 msg_signature/timestamp/nonce/echostr 到 GET /webhooks/qiwei
    Then 返回 200 text/plain 且 body 为解密明文

  Scenario: GET 握手失败
    Given callback 已启用
    When 发送非法 msg_signature 到 GET /webhooks/qiwei
    Then 返回 401 且 code=UNAUTHORIZED

  Scenario: POST text + @ 命中回复 XML
    Given callback 已启用且 require_mention=true
    And 租户已在 cutover 白名单
    When 发送合法签名解密后的 text 消息且命中 @ 规则
    Then 返回 200 且 body 为 reply XML
    And dispatch 被调用

  Scenario: POST text 非 @ 不回 XML
    Given callback 已启用且 require_mention=true
    When 发送合法 text 消息但未命中 @ 规则
    Then 返回 200 success
    And 不返回 reply XML

  Scenario: POST 非 text/事件降级 success
    Given callback 已启用
    When 发送 image/event 等合法消息
    Then 返回 200 success

  Scenario: POST 验签或解密失败
    Given callback 已启用
    When 发送错误签名或非法 Encrypt
    Then 返回 401 且 dispatch 不被调用

  Scenario: 下游超时或 5xx 失败降级
    Given callback 已启用且 dispatch 下游超时
    When 发送合法 @ text 消息
    Then 返回 200 success
    And 不返回 500

  Scenario: 幂等重复投递
    Given callback 已启用且幂等 TTL=120s
    When 同一幂等 key 在 TTL 内重复请求
    Then 不重复 side effect
    And 返回与首次一致的 success 或 XML

  Scenario: 灰度切流与回滚
    Given cutover 开关开启且 tenant 在白名单
    When 租户发起 callback
    Then 请求按策略分流到 zcpg
    When 运维关闭 cutover
    Then 后续请求分钟级恢复 legacy 路径
