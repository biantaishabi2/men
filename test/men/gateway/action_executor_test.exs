defmodule Men.Gateway.ActionExecutorTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.ActionExecutor

  test "成功执行返回 ok receipt" do
    action = %{action_id: "a1", name: "tool.echo", params: %{v: 1}}
    context = %{run_id: "run-1", session_key: "s1"}

    receipt =
      ActionExecutor.execute(action, context,
        dispatcher: fn _action, _ctx, _opts -> {:ok, %{done: true}} end
      )

    assert receipt.run_id == "run-1"
    assert receipt.action_id == "a1"
    assert receipt.status == :ok
    assert receipt.retryable == false
  end

  test "可重试失败返回 retryable=true" do
    action = %{action_id: "a2", name: "tool.fail"}
    context = %{run_id: "run-2", session_key: "s1"}

    receipt =
      ActionExecutor.execute(action, context,
        dispatcher: fn _action, _ctx, _opts ->
          {:error, %{code: "TEMP_UNAVAILABLE", message: "retry", retryable: true}}
        end
      )

    assert receipt.status == :failed
    assert receipt.code == "TEMP_UNAVAILABLE"
    assert receipt.retryable == true
  end

  test "dispatcher 返回非 map 错误时应返回 failed receipt 且不崩溃" do
    action = %{action_id: "a3", name: "tool.timeout"}
    context = %{run_id: "run-3", session_key: "s1"}

    receipt =
      ActionExecutor.execute(action, context,
        dispatcher: fn _action, _ctx, _opts -> {:error, :timeout} end
      )

    assert receipt.run_id == "run-3"
    assert receipt.action_id == "a3"
    assert receipt.status == :failed
    assert receipt.code == "ACTION_FAILED"
    assert receipt.message == ":timeout"
    assert receipt.retryable == false
    assert receipt.data == %{reason: :timeout}
  end
end
