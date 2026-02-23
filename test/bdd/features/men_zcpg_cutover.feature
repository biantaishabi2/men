Feature: men -> zcpg cutover 与回滚
  为了在租户灰度期间保证可回滚
  作为 dispatch 主链路维护者
  我需要在 zcpg 与 legacy 之间可控切换并验证回退语义

  Scenario: 白名单租户 @ 消息走 zcpg 并产生回包
    Given cutover 已开启且 tenantA 在白名单
    And zcpg 服务可用
    When tenantA 发送 "@bot 你好" 到钉钉 webhook
    Then dispatch 路由到 zcpg
    And 产生 passive final reply

  Scenario: zcpg 连续失败后自动回退到 legacy
    Given cutover 已开启且 tenantA 在白名单
    And zcpg 连续超时超过熔断阈值
    When tenantA 发送 "@bot timeout" 到钉钉 webhook
    Then dispatch 自动回退到 legacy
    And 产生 passive final reply

  Scenario: 手动 rollback 后全量走 legacy
    Given cutover 已开启且 tenantA 在白名单
    And 运维执行 rollback 关闭开关并清空白名单
    When tenantA 再次发送 "@bot after rollback" 到钉钉 webhook
    Then dispatch 不再调用 zcpg
    And 全量走 legacy 并产生 passive final reply
