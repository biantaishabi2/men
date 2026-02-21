defmodule Men.Channels.Egress.DingtalkAdapterTest do
  use ExUnit.Case, async: true

  alias Men.Channels.Egress.DingtalkAdapter

  test "final 结果映射为 HTTP200 + final body" do
    result =
      {:ok,
       %{
         request_id: "req-1",
         run_id: "run-1",
         payload: %{text: "done"}
       }}

    assert {200, body} = DingtalkAdapter.to_webhook_response(result)
    assert body.status == "final"
    assert body.code == "OK"
    assert body.message == "done"
    assert body.request_id == "req-1"
    assert body.run_id == "run-1"
  end

  test "普通错误映射为 HTTP200 + error body" do
    result =
      {:error,
       %{
         request_id: "req-2",
         run_id: "run-2",
         code: "INVALID_SIGNATURE",
         reason: "invalid signature",
         metadata: %{field: :signature}
       }}

    assert {200, body} = DingtalkAdapter.to_webhook_response(result)
    assert body.status == "error"
    assert body.code == "INVALID_SIGNATURE"
    assert body.message == "invalid signature"
    assert body.details == %{field: :signature}
  end

  test "timeout 错误映射为 HTTP200 + timeout body" do
    result =
      {:error,
       %{
         request_id: "req-3",
         run_id: "run-3",
         code: "CLI_TIMEOUT",
         reason: "runtime timeout",
         metadata: %{type: :timeout}
       }}

    assert {200, body} = DingtalkAdapter.to_webhook_response(result)
    assert body.status == "timeout"
    assert body.code == "CLI_TIMEOUT"
    assert body.message == "runtime timeout"
  end
end
