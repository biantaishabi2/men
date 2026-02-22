defmodule Men.Gateway.Runtime.ExecuteCompilerTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.Runtime.ExecuteCompiler

  test "无环任务可成功编译为拓扑层次" do
    input = %{
      tasks: [
        %{task_id: "A", blocked_by: []},
        %{task_id: "B", blocked_by: ["A"]},
        %{task_id: "C", blocked_by: ["B"]}
      ]
    }

    assert {:ok, result} = ExecuteCompiler.compile(input)
    assert result.layers == [["A"], ["B"], ["C"]]
    assert result.blocked_by == %{"A" => [], "B" => ["A"], "C" => ["B"]}
  end

  test "存在环时返回 cycle_nodes 与 edges" do
    input = %{
      tasks: [
        %{task_id: "A", blocked_by: ["C"]},
        %{task_id: "B", blocked_by: ["A"]},
        %{task_id: "C", blocked_by: ["B"]}
      ]
    }

    assert {:error, {:cycle_detected, details}} = ExecuteCompiler.compile(input)
    assert details.cycle_nodes == ["A", "B", "C", "A"]

    assert details.edges == [
             %{from: "A", to: "B"},
             %{from: "B", to: "C"},
             %{from: "C", to: "A"}
           ]
  end

  test "缺失节点时返回 missing_nodes 错误" do
    input = %{
      tasks: [
        %{task_id: "A", blocked_by: []},
        %{task_id: "B", blocked_by: ["A"]}
      ],
      edges: [
        %{from: "B", to: "C"}
      ]
    }

    assert {:error, {:missing_nodes, details}} = ExecuteCompiler.compile(input)
    assert details.missing_node_ids == ["C"]
    assert details.edges == [%{from: "B", to: "C"}]
  end
end
