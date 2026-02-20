defmodule Men.Routing.SessionKeyTest do
  use ExUnit.Case, async: true

  alias Men.Routing.SessionKey

  test "同用户同渠道连续消息生成一致 key" do
    attrs = %{channel: "feishu", user_id: "user_123"}

    assert {:ok, "feishu:user_123"} = SessionKey.build(attrs)
    assert {:ok, "feishu:user_123"} = SessionKey.build(attrs)
  end

  test "group 和 thread 组合能区分 key" do
    attrs = %{
      channel: "feishu",
      user_id: "user_123",
      group_id: "grp_A",
      thread_id: "thr_1"
    }

    assert {:ok, "feishu:user_123:g:grp_A:t:thr_1"} = SessionKey.build(attrs)
  end

  test "缺少可选字段时仅生成基础段" do
    attrs = %{channel: "dingtalk", user_id: "u456"}

    assert {:ok, "dingtalk:u456"} = SessionKey.build(attrs)
  end

  test "可选字段为空字符串时会被忽略" do
    attrs = %{channel: "feishu", user_id: "user_123", group_id: "", thread_id: ""}

    assert {:ok, "feishu:user_123"} = SessionKey.build(attrs)
  end

  test "非法字段值被拒绝" do
    attrs = %{channel: "feishu", user_id: "user:bad"}

    assert {:error, :invalid_segment} = SessionKey.build(attrs)
  end

  test "可选字段包含非法字符时返回错误" do
    attrs = %{channel: "feishu", user_id: "user_123", group_id: "grp:bad"}

    assert {:error, :invalid_segment} = SessionKey.build(attrs)
  end

  test "缺少必填字段返回缺失错误" do
    attrs = %{channel: "feishu"}

    assert {:error, :missing_required_field} = SessionKey.build(attrs)
  end
end
