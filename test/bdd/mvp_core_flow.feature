# language: zh-CN
功能: Men 核心链路 MVP
  为了保证 Feishu 与 DingTalk 共用主干控制面
  作为网关维护者
  我需要统一验签、路由、bridge 与异步回写语义

  场景: Happy Path Feishu
    假如 收到一个合法签名的 Feishu 文本 webhook
    当 事件进入 DispatchServer 主状态机
    那么 应该完成 session_key 计算
    而且 bridge 返回成功结果
    并且 final 结果被异步回写

  场景: Happy Path DingTalk
    假如 收到一个合法签名的 DingTalk 文本 webhook
    当 事件进入 DispatchServer 主状态机
    那么 应该完成 session_key 计算
    而且 bridge 返回成功结果
    并且 final 结果被异步回写

  场景: 验签失败双渠道
    假如 收到一个非法签名 webhook
    当 ingress adapter 执行 normalize
    那么 应该返回 signature_invalid
    并且 bridge 不会被调用

  场景: Bridge 失败双渠道
    假如 bridge 返回 timeout 或 error
    当 DispatchServer 执行 egress 错误回写
    那么 应该回写错误摘要
    并且 日志包含 request_id session_key run_id

  场景: 同 Session 连续消息
    假如 同一用户在同一会话连续发送两条消息
    当 两条消息都进入主链路
    那么 session_key 应保持一致
    并且 每条消息都有唯一 run_id
