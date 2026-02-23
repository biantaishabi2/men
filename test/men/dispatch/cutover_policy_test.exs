defmodule Men.Dispatch.CutoverPolicyTest do
  use ExUnit.Case, async: true

  alias Men.Dispatch.CutoverPolicy

  test "非@消息被硬门禁拦截" do
    event = %{
      channel: "dingtalk",
      payload: %{content: "你好"},
      metadata: %{mention_required: true}
    }

    assert CutoverPolicy.route(event, config: [enabled: true, tenant_whitelist: ["tenantA"]]) ==
             :ignore
  end

  test "enabled=false 时全量 legacy" do
    event = %{
      channel: "dingtalk",
      payload: %{content: "@bot 你好"},
      metadata: %{tenant_id: "tenantA", mention_required: true}
    }

    assert CutoverPolicy.route(event, config: [enabled: false, tenant_whitelist: ["tenantA"]]) ==
             :legacy
  end

  test "tenant 白名单命中走 zcpg" do
    event = %{
      channel: "dingtalk",
      payload: %{content: "@bot 你好"},
      metadata: %{tenant_id: "tenantA", mention_required: true}
    }

    assert CutoverPolicy.route(event, config: [enabled: true, tenant_whitelist: ["tenantA"]]) ==
             :zcpg
  end

  test "tenant 未命中即使 env_override 也不突破白名单" do
    event = %{
      channel: "dingtalk",
      payload: %{content: "@bot 你好"},
      metadata: %{tenant_id: "tenantB", mention_required: true}
    }

    cfg = [enabled: false, env_override: true, tenant_whitelist: ["tenantA"]]

    assert CutoverPolicy.route(event, config: cfg, env: :dev) == :legacy
  end

  test "tenant 优先于环境开关" do
    event = %{
      channel: "dingtalk",
      payload: %{content: "@bot 你好"},
      metadata: %{tenant_id: "tenantA", mention_required: true}
    }

    cfg = [enabled: true, env_override: false, tenant_whitelist: ["tenantA"]]

    assert CutoverPolicy.route(event, config: cfg, env: :prod) == :zcpg
  end
end
