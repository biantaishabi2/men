defmodule Men.RuntimeBridge.GongRPCTest do
  use ExUnit.Case, async: false

  alias Men.RuntimeBridge.{Error, GongRPC, Request, Response}

  defmodule FakeRPC do
    def call(node_name, remote_module, remote_function, [payload], timeout_ms) do
      if pid = Application.get_env(:men, :gong_rpc_test_pid) do
        send(pid, {:rpc_called, node_name, remote_module, remote_function, payload, timeout_ms})
      end

      apply(remote_module, remote_function, [payload])
    end
  end

  defmodule FakeRemote do
    def open(payload) do
      {:ok,
       %{
         runtime_id: payload.runtime_id,
         session_id: payload.session_id || "sess-opened",
         payload: %{status: :opened},
         metadata: %{source: :fake_remote}
       }}
    end

    def get(payload) do
      {:ok,
       %{
         runtime_id: payload.runtime_id,
         session_id: payload.session_id,
         payload: %{status: :active},
         metadata: %{source: :fake_remote}
       }}
    end

    def prompt(%{payload: "rpc_timeout"}), do: {:badrpc, :timeout}
    def prompt(%{payload: "transport_error"}), do: {:badrpc, :nodedown}

    def prompt(%{payload: "rpc_error"}) do
      {:error,
       %{
         code: :runtime_error,
         message: "remote failed",
         retryable: false,
         context: %{source: :fake_remote}
       }}
    end

    def prompt(%{session_id: "missing"}) do
      {:error,
       %{
         code: :session_not_found,
         message: "runtime session not found",
         retryable: true,
         context: %{session_id: "missing"}
       }}
    end

    def prompt(payload) do
      {:ok,
       %{
         runtime_id: payload.runtime_id,
         session_id: payload.session_id,
         payload: "reply:" <> to_string(payload.payload),
         metadata: %{source: :fake_remote}
       }}
    end

    def close(%{session_id: "missing"}) do
      {:error,
       %{
         code: :session_not_found,
         message: "runtime session not found",
         retryable: true,
         context: %{session_id: "missing"}
       }}
    end

    def close(payload) do
      {:ok,
       %{
         runtime_id: payload.runtime_id,
         session_id: payload.session_id,
         payload: :closed,
         metadata: %{source: :fake_remote}
       }}
    end
  end

  setup do
    original_runtime_bridge = Application.get_env(:men, :runtime_bridge, [])

    Application.put_env(:men, :gong_rpc_test_pid, self())

    Application.put_env(:men, :runtime_bridge,
      original_runtime_bridge
      |> Keyword.put(:rpc_module, FakeRPC)
      |> Keyword.put(:gong_node, :"gong@test")
      |> Keyword.put(:rpc_timeout_ms, 120)
      |> Keyword.put(:rpc_target, %{
        open: {FakeRemote, :open},
        get: {FakeRemote, :get},
        prompt: {FakeRemote, :prompt},
        close: {FakeRemote, :close}
      })
    )

    on_exit(fn ->
      Application.put_env(:men, :runtime_bridge, original_runtime_bridge)
      Application.delete_env(:men, :gong_rpc_test_pid)
    end)

    :ok
  end

  test "正常 RPC 路径 open -> prompt -> close 返回新契约结构" do
    open_request = %Request{runtime_id: "gong", session_id: nil, payload: %{mode: :new}}
    prompt_request = %Request{runtime_id: "gong", session_id: "sess-1", payload: "hello"}
    close_request = %Request{runtime_id: "gong", session_id: "sess-1", payload: nil}

    assert {:ok, %Response{} = open_response} = GongRPC.open(open_request)
    assert open_response.payload == %{status: :opened}

    assert {:ok, %Response{} = prompt_response} = GongRPC.prompt(prompt_request)
    assert prompt_response.payload == "reply:hello"

    assert {:ok, %Response{} = close_response} = GongRPC.close(close_request)
    assert close_response.payload == :closed

    assert_receive {:rpc_called, :"gong@test", FakeRemote, :open, _, 120}
    assert_receive {:rpc_called, :"gong@test", FakeRemote, :prompt, _, 120}
    assert_receive {:rpc_called, :"gong@test", FakeRemote, :close, _, 120}
  end

  test "session_not_found 映射为 retryable=true 的统一错误" do
    request = %Request{runtime_id: "gong", session_id: "missing", payload: "hello"}

    assert {:error, %Error{} = error} = GongRPC.prompt(request)
    assert error.code == :session_not_found
    assert error.retryable == true
    assert error.context == %{session_id: "missing"}
  end

  test "RPC 超时映射为 timeout 且不泄漏底层格式" do
    request = %Request{runtime_id: "gong", session_id: "sess-timeout", payload: "rpc_timeout", timeout_ms: 50}

    assert {:error, %Error{} = error} = GongRPC.prompt(request)
    assert error.code == :timeout
    assert error.retryable == true
    refute String.contains?(error.message, "badrpc")
  end

  test "传输错误与运行时错误映射稳定" do
    transport_request = %Request{runtime_id: "gong", session_id: "sess-transport", payload: "transport_error"}
    runtime_request = %Request{runtime_id: "gong", session_id: "sess-runtime", payload: "rpc_error"}

    assert {:error, %Error{} = transport_error} = GongRPC.prompt(transport_request)
    assert transport_error.code == :transport_error
    assert transport_error.retryable == true

    assert {:error, %Error{} = runtime_error} = GongRPC.prompt(runtime_request)
    assert runtime_error.code == :runtime_error
    assert runtime_error.retryable == false
  end

  test "close 对 session_not_found 幂等处理" do
    request = %Request{runtime_id: "gong", session_id: "missing", payload: nil}

    assert {:ok, %Response{} = response} = GongRPC.close(request)
    assert response.payload == :closed
    assert response.metadata.idempotent == true
  end

  test "调用进程重启边界下行为一致，不依赖进程内会话状态" do
    request = %Request{runtime_id: "gong", session_id: "sess-restart", payload: "hello"}

    assert {:ok, %Response{} = first_result} = invoke_in_worker(request)
    assert {:ok, %Response{} = second_result} = invoke_in_worker(request)

    assert first_result.payload == "reply:hello"
    assert second_result.payload == "reply:hello"

    assert_receive {:rpc_called, :"gong@test", FakeRemote, :prompt, %{session_id: "sess-restart"}, 120}
    assert_receive {:rpc_called, :"gong@test", FakeRemote, :prompt, %{session_id: "sess-restart"}, 120}
  end

  defp invoke_in_worker(request) do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:worker_result, GongRPC.prompt(request)})
      end)

    assert_receive {:worker_result, result}, 1_000

    if Process.alive?(pid) do
      Process.exit(pid, :kill)
    end

    result
  end
end
