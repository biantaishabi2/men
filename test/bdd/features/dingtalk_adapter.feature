Feature: DingTalk Adapter L1
  为了让钉钉消息可靠进入主链路
  作为控制面接入层
  我需要 ingress/egress/controller 协同完成最小闭环

  Scenario: 合法 webhook 进入主链路并返回 final
    Given 存在一个签名正确且在 5 分钟窗口内的钉钉事件
    When 事件发送到 /webhooks/dingtalk
    Then 事件被标准化后进入 dispatch 主链路
    And webhook 回写 HTTP 200
    And body.status 为 "final"

  Scenario: 非法签名请求被拒绝
    Given 一个签名错误或缺失签名的钉钉事件
    When 事件发送到 /webhooks/dingtalk
    Then 请求不会进入 dispatch 主链路
    And webhook 回写 HTTP 200
    And body.status 为 "error"
    And body.code 为 "INVALID_SIGNATURE"

  Scenario: bridge 超时返回 timeout 语义
    Given 一个签名合法的钉钉事件
    And dispatch/bridge 返回 timeout 错误
    When 事件发送到 /webhooks/dingtalk
    Then webhook 回写 HTTP 200
    And body.status 为 "timeout"
    And body.code 为 "CLI_TIMEOUT"
