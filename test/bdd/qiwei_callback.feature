Feature: qiwei callback ingress + passive reply
  为了在企微回调模式下稳定接入 men 并支持被动回复
  作为 webhook 维护者
  我需要在验签解密、分流、幂等与回滚时保持协议语义稳定

  Scenario: GET 握手成功
    Given msg_signature/timestamp/nonce/echostr 均合法
    When 请求 GET /webhooks/qiwei
    Then 返回 200 text/plain 且 body 为解密后的 echostr 明文

  Scenario: POST text @命中返回被动回复 XML
    Given callback 验签解密成功
    And 文本消息命中 @ 规则
    When 请求 POST /webhooks/qiwei
    Then dispatch 被调用
    And 返回 200 与被动回复 XML

  Scenario: POST text 非@ 不回 XML
    Given callback 验签解密成功
    And 文本消息未命中 @ 规则
    When 请求 POST /webhooks/qiwei
    Then 返回 200 success

  Scenario: 下游异常降级
    Given callback 验签解密成功
    And zcpg 下游超时或返回 5xx
    When 请求 POST /webhooks/qiwei
    Then 返回 200 success 且不返回 500

  Scenario: 切流与回滚
    Given QIWEI_CUTOVER_ENABLED=true 且租户在白名单
    When 发送 @ 消息
    Then 请求走 zcpg 路径
    When 关闭 cutover 开关
    Then 分钟级恢复 legacy 路径
