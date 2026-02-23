defmodule Men.RuntimeBridge.BridgeTest do
  use ExUnit.Case, async: true

  alias Men.RuntimeBridge.{ErrorResponse, Request, Response}

  defmodule MockRuntimeBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def call(%Request{session_key: session_key, content: "ok"}, _opts) do
      {:ok,
       %Response{session_key: session_key, content: "runtime-ok", metadata: %{source: :mock}}}
    end

    def call(%Request{session_key: session_key}, _opts) do
      {:error,
       %ErrorResponse{
         session_key: session_key,
         reason: "runtime-failed",
         code: "runtime_error",
         metadata: %{source: :mock}
       }}
    end
  end

  defmodule MockGraphAdapter do
    def run(:research_reduce, %{"topic" => topic}, _opts) do
      {:ok,
       %{action: :research_reduce, result: "ok", data: %{"topic" => topic}, diagnostics: %{}}}
    end

    def run(_action, _payload, _opts) do
      {:error,
       %ErrorResponse{
         session_key: "taskctl",
         reason: "unsupported",
         code: "graph_contract_error",
         metadata: %{}
       }}
    end
  end

  test "Request 结构体可构造" do
    req = %Request{session_key: "feishu:u1", content: "hello", metadata: %{trace: "t1"}}

    assert req.session_key == "feishu:u1"
    assert req.content == "hello"
    assert req.metadata == %{trace: "t1"}
  end

  test "Response 和 ErrorResponse 结构体可构造" do
    resp = %Response{session_key: "feishu:u1", content: "done", metadata: %{token: "x"}}

    err = %ErrorResponse{
      session_key: "feishu:u1",
      reason: "failed",
      code: "bad_input",
      metadata: %{}
    }

    assert resp.content == "done"
    assert err.reason == "failed"
    assert err.code == "bad_input"
  end

  test "mock bridge 满足 behaviour 返回标准结果" do
    ok_req = %Request{session_key: "feishu:u1", content: "ok"}
    fail_req = %Request{session_key: "feishu:u1", content: "bad"}

    assert {:ok, %Response{content: "runtime-ok"}} = MockRuntimeBridge.call(ok_req, [])

    assert {:error, %ErrorResponse{reason: "runtime-failed"}} =
             MockRuntimeBridge.call(fail_req, [])
  end

  test "graph 通过可替换 adapter 调用三图能力" do
    assert {:ok, result} =
             Men.RuntimeBridge.Bridge.graph(:research_reduce, %{"topic" => "otp"},
               graph_adapter: MockGraphAdapter
             )

    assert result.result == "ok"
    assert result.data["topic"] == "otp"
  end
end
