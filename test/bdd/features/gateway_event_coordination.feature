Feature: Gateway event coordination
  作为网关事件协调层
  我希望对事件做入箱、去重与唤醒判定
  以便主链路在不回归 cutover 语义的前提下稳定运行

  Scenario: agent_result 只唤醒一次
    Given 一个 child 事件 type 为 "agent_result" 且 event_id 为 "e1"
    When DispatchServer 连续两次协调该事件
    Then 第一次应 wake_decision 为 true 且触发一次回调
    And 第二次应 duplicate 为 true 且不再触发回调

  Scenario: tool_progress 仅入箱
    Given 一个事件 type 为 "tool_progress"
    When DispatchServer 协调该事件
    Then wake_decision 为 false
    And inbox_only 为 true

  Scenario: Ops Policy 不可用时策略降级
    Given Ops Policy 拉取失败
    When DispatchServer 协调任意事件
    Then 使用 fail-closed 策略
    And policy_version 应为 "fallback"
