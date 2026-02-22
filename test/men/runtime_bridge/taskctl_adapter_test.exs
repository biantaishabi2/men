defmodule Men.RuntimeBridge.TaskctlAdapterTest do
  use ExUnit.Case, async: true

  alias Men.RuntimeBridge.TaskctlAdapter
  alias Men.RuntimeBridge.ErrorResponse

  test "run 成功返回标准化结果" do
    runner = fn _cmd, args, input ->
      assert ["research", "reduce"] == args
      assert is_binary(input)

      {
        ~s({"result":"ok","graph":{"nodes":2},"diagnostics":{"source":"taskctl"}}),
        0
      }
    end

    assert {:ok, result} =
             TaskctlAdapter.run(:research_reduce, %{"goal" => "find"}, runner: runner)

    assert result.action == :research_reduce
    assert result.result == "ok"
    assert result.data["graph"] == %{"nodes" => 2}
    assert result.diagnostics["source"] == "taskctl"
  end

  test "run 在命令失败时返回 ErrorResponse" do
    runner = fn _cmd, _args, _input -> {"boom", 127} end

    assert {:error, %ErrorResponse{} = error} =
             TaskctlAdapter.run(:research_reduce, %{"choices" => []}, runner: runner)

    assert error.code == "taskctl_exit_non_zero"
    assert error.metadata[:exit_status] == 127
  end

  test "run 在输出非 json 时返回契约错误" do
    runner = fn _cmd, _args, _input -> {"not-json", 0} end

    assert {:error, %ErrorResponse{} = error} =
             TaskctlAdapter.run(:execute_compile, %{"tasks" => []}, runner: runner)

    assert error.code == "graph_contract_error"
    assert String.contains?(error.reason, "invalid json output")
  end
end
