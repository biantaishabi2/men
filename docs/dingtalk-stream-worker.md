# DingTalk Stream Worker 接入说明

本文档说明如何使用 Go sidecar 将钉钉 Stream 消息转发到 men。

## 架构

1. `dingtalk-stream-worker` 通过钉钉 Stream SDK 接收机器人消息。
2. worker 将消息转发到 `men` 内部接口：`POST /internal/dingtalk/stream`。
3. men 通过 `DispatchServer` 调用 runtime bridge，再通过 `DingtalkRobotAdapter` 回发。

## men 侧新增入口

- 路由：`POST /internal/dingtalk/stream`
- 鉴权：
  - Header `x-men-internal-token: <token>`，或
  - Header `Authorization: Bearer <token>`
- men 环境变量：
  - `DINGTALK_STREAM_INTERNAL_TOKEN`（必填）

## worker 配置

worker 读取以下环境变量：

- `DINGTALK_APP_KEY`（必填）
- `DINGTALK_APP_SECRET`（必填）
- `DINGTALK_STREAM_INTERNAL_TOKEN`（必填）
- `DINGTALK_STREAM_TOPIC`（可选，默认 `/v1.0/im/bot/messages/get`）
- `MEN_INTERNAL_INGRESS_URL`（可选，默认 `http://127.0.0.1:4010/internal/dingtalk/stream`）
- `MEN_INTERNAL_INGRESS_TIMEOUT_MS`（可选，默认 `10000`）
- `DINGTALK_STREAM_DEBUG`（可选，`true/false`）

## 本地启动

```bash
cd tools/dingtalk-stream-worker
go mod tidy
go run .
```

## 验证建议

1. men 与 worker 同机启动。
2. 在钉钉中向应用机器人发送文本消息。
3. 观察 men 日志是否出现 `/internal/dingtalk/stream` 请求与对应 dispatch run。
4. 观察钉钉侧是否收到回发消息。

## 说明

- 当前 MVP 仅转发文本消息（`text.content`）。
- 非文本消息会被忽略，不进入主链路。
