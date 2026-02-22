defmodule Men.RuntimeBridge.GongRPCTest do
  use ExUnit.Case, async: false

  alias Men.RuntimeBridge.GongRPC

  defmodule MockNodeConnector do
    def ensure_connected(_cfg, _rpc_client) do
      case Application.get_env(:men, :gong_rpc_test_connector_mode, :ok) do
        :ok -> {:ok, :"gong@127.0.0.1"}
        :error -> {:error, %{type: :failed, code: "NODE_DISCONNECTED", message: "node down", details: %{}}}
      end
    end
  end

  defmodule MockRPCClient do
    def call(_node, Gong.SessionManager, :create_session, _args, _timeout) do
      mode = Application.get_env(:men, :gong_rpc_test_mode, :success)

      if mode == :create_badrpc do
        {:badrpc, :nodedown}
      else
        pid = spawn(fn -> Process.sleep(:infinity) end)
        {:ok, pid, "session_test_1"}
      end
    end

    def call(_node, Gong.Session, :subscribe, [_pid, _subscriber], _timeout), do: :ok

    def call(_node, Gong.Session, :prompt, [_pid, _prompt, _opts], _timeout) do
      mode = Application.get_env(:men, :gong_rpc_test_mode, :success)

      case mode do
        :success ->
          send(self(), {:session_event, %{type: "lifecycle.result", payload: %{assistant_text: "rpc ok"}}})
          send(self(), {:session_event, %{type: "lifecycle.completed"}})
          :ok

        :lifecycle_error ->
          send(self(), {:session_event, %{type: "lifecycle.error", error: %{message: "broken"}}})
          :ok

        :timeout ->
          :ok

        _ ->
          :ok
      end
    end

    def call(_node, Gong.SessionManager, :close_session, [_session_id], _timeout), do: :ok

    def call(_node, Gong.Session, :history, [_pid], _timeout), do: {:ok, [%{role: :assistant, content: "history text"}]}

    def call(_node, Gong.Session, :get_last_assistant_message, [history], _timeout) do
      case history do
        [%{content: text} | _] -> text
        _ -> ""
      end
    end

    def ping(_node), do: :pong
  end

  setup do
    original = Application.get_env(:men, GongRPC, [])

    Application.put_env(:men, GongRPC,
      rpc_client: MockRPCClient,
      node_connector: MockNodeConnector,
      rpc_timeout_ms: 200,
      completion_timeout_ms: 300,
      model: "deepseek:deepseek-chat"
    )

    Application.put_env(:men, :gong_rpc_test_mode, :success)
    Application.put_env(:men, :gong_rpc_test_connector_mode, :ok)

    on_exit(fn ->
      Application.put_env(:men, GongRPC, original)
      Application.delete_env(:men, :gong_rpc_test_mode)
      Application.delete_env(:men, :gong_rpc_test_connector_mode)
    end)

    :ok
  end

  test "RPC 正常链路返回统一成功结构" do
    assert {:ok, payload} =
             GongRPC.start_turn("hello", %{
               request_id: "req-rpc-1",
               session_key: "dingtalk:u1",
               run_id: "run-rpc-1"
             })

    assert payload.text == "rpc ok"
    assert payload.meta.request_id == "req-rpc-1"
    assert payload.meta.session_key == "dingtalk:u1"
    assert payload.meta.run_id == "run-rpc-1"
    assert payload.meta.transport == "rpc"
  end

  test "lifecycle.error 映射为 bridge 失败结构" do
    Application.put_env(:men, :gong_rpc_test_mode, :lifecycle_error)

    assert {:error, error} =
             GongRPC.start_turn("hello", %{
               request_id: "req-rpc-2",
               session_key: "dingtalk:u2",
               run_id: "run-rpc-2"
             })

    assert error.type == :failed
    assert error.code == "RPC_LIFECYCLE_ERROR"
    assert error.request_id == "req-rpc-2"
  end

  test "节点不可用时返回 NODE_DISCONNECTED" do
    Application.put_env(:men, :gong_rpc_test_connector_mode, :error)

    assert {:error, error} =
             GongRPC.start_turn("hello", %{
               request_id: "req-rpc-3",
               session_key: "dingtalk:u3",
               run_id: "run-rpc-3"
             })

    assert error.code == "NODE_DISCONNECTED"
    assert error.type == :failed
  end

  test "等待 completion 超时返回 RPC_TIMEOUT" do
    Application.put_env(:men, :gong_rpc_test_mode, :timeout)
    Application.put_env(:men, GongRPC, Application.get_env(:men, GongRPC, []) |> Keyword.put(:completion_timeout_ms, 60))

    assert {:error, error} =
             GongRPC.start_turn("hello", %{
               request_id: "req-rpc-4",
               session_key: "dingtalk:u4",
               run_id: "run-rpc-4"
             })

    assert error.type == :timeout
    assert error.code == "RPC_TIMEOUT"
  end
end

