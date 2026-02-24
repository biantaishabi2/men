defmodule Men.Gateway.Runtime.GraphContractTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.Runtime.GraphContract

  test "build_request 接受合法 action 和 map payload" do
    assert {:ok, request} = GraphContract.build_request(:research_reduce, %{"topic" => "x"})
    assert request.action == :research_reduce
    assert request.input == %{"topic" => "x"}
  end

  test "build_request 拒绝非法 action" do
    assert {:error, "unsupported action"} = GraphContract.build_request(:unknown, %{})
  end

  test "build_request 拒绝非 map payload" do
    assert {:error, "payload must be a map"} =
             GraphContract.build_request(:research_reduce, "bad")
  end

  test "normalize_response 归一化数据并保留 diagnostics" do
    raw = %{
      "result" => "ok",
      "plan" => %{"selected" => "A"},
      "diagnostics" => %{"score" => 0.93}
    }

    assert {:ok, normalized} = GraphContract.normalize_response(:research_reduce, raw)
    assert normalized.action == :research_reduce
    assert normalized.result == "ok"
    assert normalized.data["plan"] == %{"selected" => "A"}
    assert normalized.diagnostics["score"] == 0.93
  end

  test "normalize_response 缺少 result 时报错" do
    assert {:error, "missing result field"} =
             GraphContract.normalize_response(:execute_compile, %{"dag" => %{}})
  end
end
