# Channel Integration References

本文件记录 `men` 频道接入实现可复用的外部参考，先聚焦钉钉。

## DingTalk References

### 1. ZCPG（Elixir）可复用实现

- 机器人发送实现（markdown + 可选签名）  
  `../zcpg/lib/zcpg/integrations/ding_talk/robot.ex`

- 运行时配置入口（推荐环境变量）  
  `../zcpg/config/runtime.exs`
  - `DINGTALK_ROBOT_WEBHOOK_URL`
  - `DINGTALK_ROBOT_SECRET`
  - `DINGTALK_ROBOT_SIGN_ENABLED`

- 本地开发配置（含历史 webhook 示例）  
  `../zcpg/config/dev.exs`

### 2. Webhook 项目（Python/FastAPI）参考

- 项目路径  
  `../wangbo/dev/webhook`

- 通用 webhook 路由入口  
  `../wangbo/dev/webhook/app/routers/webhooks.py`

- Tower root webhook 处理示例  
  `../wangbo/dev/webhook/app/main.py`

说明：该项目当前主要是通用 webhook/Tower 流程，没有现成 Feishu 业务实现。

### 3. DingTalk 脚本与流程样例（ZCPG）

- 审批 API 脚本（流程字段/媒体上传处理）  
  `../zcpg/priv/skills/public/dingtalk/dingtalk_approval_api.sh`

- 报销自动流程脚本  
  `../zcpg/priv/skills/public/dingtalk/dingtalk_expense_workflow.sh`

- 发票转审批流程脚本  
  `../zcpg/priv/skills/public/dingtalk/invoice_to_dingtalk_approval.sh`

## Men 实施时的落地原则

1. 渠道差异只进 adapter：`DingTalkIngressAdapter` / `DingTalkEgressAdapter`。  
2. 主链路固定：`Ingress -> Route/Session -> RuntimeBridge(gong) -> Egress`。  
3. 禁止把渠道 SDK 逻辑写进 `gateway_control_plane`。  
4. 所有 key/secret/webhook 仅走环境变量，不在仓库写死。
