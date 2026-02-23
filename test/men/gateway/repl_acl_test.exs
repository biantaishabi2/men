defmodule Men.Gateway.ReplAclTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Men.Gateway.ReplAcl

  @policy %{
    acl: %{
      "main" => %{"read" => ["global.", "agent."], "write" => ["global.control."]},
      "child" => %{
        "read" => ["agent.$agent_id.", "shared.evidence.agent.$agent_id."],
        "write" => ["agent.$agent_id.", "shared.evidence.agent.$agent_id."]
      },
      "tool" => %{"read" => ["agent.$agent_id."], "write" => ["inbox."]},
      "system" => %{"read" => [""], "write" => [""]}
    },
    policy_version: "test-v1"
  }

  test "ACL 越权写拦截: child 不能写 global.control" do
    actor = %{role: :child, agent_id: "agent_a", session_key: "s1"}

    assert {:error, :acl_denied} =
             ReplAcl.authorize_write(actor, "global.control.mode", @policy, %{event_id: "e1"})
  end

  test "ACL 越权读拦截: tool 缺失 agent_id 直接拒绝" do
    actor = %{role: :tool, tool_id: "t1", session_key: "s1"}

    assert {:error, :acl_denied} =
             ReplAcl.authorize_read(actor, "agent.agent_a.data.x", @policy, %{event_id: "e2"})
  end

  test "main/child/tool 权限边界" do
    main = %{role: :main, session_key: "s1"}
    child = %{role: :child, agent_id: "agent_a", session_key: "s1"}
    tool = %{role: :tool, agent_id: "agent_a", tool_id: "t1", session_key: "s1"}

    assert :ok = ReplAcl.authorize_write(main, "global.control.mode", @policy, %{})
    assert :ok = ReplAcl.authorize_write(child, "agent.agent_a.data.result", @policy, %{})

    assert {:error, :acl_denied} =
             ReplAcl.authorize_write(tool, "agent.agent_a.data.result", @policy, %{})
  end

  test "acl_denied 日志包含最小字段集合" do
    actor = %{role: :tool, tool_id: "t1", session_key: "s1"}

    log =
      capture_log(fn ->
        assert {:error, :acl_denied} =
                 ReplAcl.authorize_read(actor, "agent.agent_a.data.x", @policy, %{
                   event_id: "e3",
                   type: "tool_progress",
                   source: "tool.t1"
                 })
      end)

    assert log =~ "acl_denied"
    assert log =~ "\"event_id\":\"e3\""
    assert log =~ "\"session_key\":\"s1\""
    assert log =~ "\"type\":\"tool_progress\""
    assert log =~ "\"source\":\"tool.t1\""
    assert log =~ "\"wake\":false"
    assert log =~ "\"inbox_only\":false"
    assert log =~ "\"decision_reason\":\"acl_denied\""
    assert log =~ "\"policy_version\":\"test-v1\""
  end
end
