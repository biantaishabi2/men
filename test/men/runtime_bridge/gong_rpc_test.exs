defmodule Men.RuntimeBridge.GongRPCTest do
  use ExUnit.Case, async: false

  alias Men.RuntimeBridge.GongRPC

  defmodule MockNodeConnector do
    def ensure_connected(_cfg, _rpc_client) do
      case Application.get_env(:men, :gong_rpc_test_connector_mode, :ok) do
        :ok ->
          {:ok, :"gong@127.0.0.1"}

        :error ->
          {:error,
           %{type: :failed, code: "NODE_DISCONNECTED", message: "node down", details: %{}}}
      end
    end
  end

  defmodule MockRPCClient do
    def call(_node, Gong.SessionManager, :create_session, _args, _timeout) do
      mode = Application.get_env(:men, :gong_rpc_test_mode, :success)
      notify({:rpc_create_session, mode})

      if mode == :create_badrpc do
        {:badrpc, :nodedown}
      else
        session_id =
          "session_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

        pid = spawn(fn -> Process.sleep(:infinity) end)
        :ok = register_session(pid, session_id)
        {:ok, pid, session_id}
      end
    end

    def call(_node, Gong.Session, :subscribe, [_pid, _subscriber], _timeout), do: :ok

    def call(_node, Gong.Session, :prompt, [pid, _prompt, _opts], _timeout) do
      mode = Application.get_env(:men, :gong_rpc_test_mode, :success)
      notify({:rpc_prompt, pid, mode})

      case mode do
        :success ->
          send(
            self(),
            {:session_event, %{type: "lifecycle.result", payload: %{assistant_text: "rpc ok"}}}
          )

          send(self(), {:session_event, %{type: "lifecycle.completed"}})
          :ok

        :with_delta ->
          send(self(), {:session_event, %{type: "message.delta", payload: %{content: "part-1"}}})
          send(self(), {:session_event, %{type: "message.delta", payload: %{content: "part-2"}}})

          send(
            self(),
            {:session_event, %{type: "lifecycle.result", payload: %{assistant_text: "rpc ok"}}}
          )

          send(self(), {:session_event, %{type: "lifecycle.completed"}})
          :ok

        :with_noise_events ->
          send(self(), {:session_event, %{type: "lifecycle.received", payload: %{}}})
          send(self(), {:session_event, %{type: "message.start", payload: %{}}})

          send(
            self(),
            {:session_event, %{type: "tool.start", payload: %{tool_name: "list_directory"}}}
          )

          send(self(), {:session_event, %{type: "message.delta", payload: %{content: "part-a"}}})

          send(
            self(),
            {:session_event, %{type: "tool.end", payload: %{tool_name: "list_directory"}}}
          )

          send(self(), {:session_event, %{type: "message.end", payload: %{}}})

          send(
            self(),
            {:session_event,
             %{type: "lifecycle.result", payload: %{assistant_text: "rpc noisy ok"}}}
          )

          send(self(), {:session_event, %{type: "lifecycle.completed"}})
          :ok

        :session_not_found_once ->
          mark = :prompt_once_global
          count = Process.get(mark, 0) + 1
          Process.put(mark, count)

          if count == 1 do
            {:error, :session_not_found}
          else
            send(
              self(),
              {:session_event,
               %{type: "lifecycle.result", payload: %{assistant_text: "rpc rebuilt"}}}
            )

            send(self(), {:session_event, %{type: "lifecycle.completed"}})
            :ok
          end

        :lifecycle_error ->
          send(self(), {:session_event, %{type: "lifecycle.error", error: %{message: "broken"}}})
          :ok

        :timeout ->
          :ok

        _ ->
          :ok
      end
    end

    def call(_node, Gong.SessionManager, :close_session, [session_id], _timeout) do
      notify({:rpc_close_session, session_id})
      :ok
    end

    def call(_node, Gong.Session, :history, [_pid], _timeout),
      do: {:ok, [%{role: :assistant, content: "history text"}]}

    def call(_node, Gong.Session, :get_last_assistant_message, [history], _timeout) do
      case history do
        [%{content: text} | _] -> text
        _ -> ""
      end
    end

    def ping(_node), do: :pong

    defp register_session(pid, session_id) do
      sessions = Application.get_env(:men, :gong_rpc_test_sessions, %{})
      Application.put_env(:men, :gong_rpc_test_sessions, Map.put(sessions, pid, session_id))
      :ok
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :gong_rpc_test_pid) do
        send(pid, message)
      end

      :ok
    end
  end

  setup do
    original = Application.get_env(:men, GongRPC, [])
    :ok = GongRPC.__reset_session_registry_for_test__()

    Application.put_env(:men, GongRPC,
      rpc_client: MockRPCClient,
      node_connector: MockNodeConnector,
      rpc_timeout_ms: 200,
      completion_timeout_ms: 300,
      model: "deepseek:deepseek-chat",
      session_cleanup_interval_ms: 1,
      session_idle_ttl_ms: 10_000,
      max_session_entries: 1_000
    )

    Application.put_env(:men, :gong_rpc_test_pid, self())
    Application.put_env(:men, :gong_rpc_test_mode, :success)
    Application.put_env(:men, :gong_rpc_test_connector_mode, :ok)
    Application.put_env(:men, :gong_rpc_test_sessions, %{})

    on_exit(fn ->
      Application.put_env(:men, GongRPC, original)
      Application.delete_env(:men, :gong_rpc_test_mode)
      Application.delete_env(:men, :gong_rpc_test_connector_mode)
      Application.delete_env(:men, :gong_rpc_test_pid)
      Application.delete_env(:men, :gong_rpc_test_sessions)
      :ok = GongRPC.__reset_session_registry_for_test__()
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

  test "同一 session_key 连续请求会复用会话，不会每轮关闭" do
    assert {:ok, _} =
             GongRPC.start_turn("hello-1", %{
               request_id: "req-rpc-reuse-1",
               session_key: "dingtalk:reuse",
               run_id: "run-1"
             })

    assert {:ok, _} =
             GongRPC.start_turn("hello-2", %{
               request_id: "req-rpc-reuse-2",
               session_key: "dingtalk:reuse",
               run_id: "run-2"
             })

    assert_receive {:rpc_create_session, :success}
    refute_receive {:rpc_create_session, :success}
    refute_receive {:rpc_close_session, _}
  end

  test "传入 event_callback 时会实时收到 delta 事件" do
    Application.put_env(:men, :gong_rpc_test_mode, :with_delta)
    parent = self()

    callback = fn event -> send(parent, {:stream_event, event}) end

    assert {:ok, payload} =
             GongRPC.start_turn("hello-delta", %{
               request_id: "req-rpc-delta-1",
               session_key: "dingtalk:delta",
               run_id: "run-rpc-delta-1",
               event_callback: callback
             })

    assert payload.text == "rpc ok"
    assert_receive {:stream_event, %{type: :delta, payload: %{text: "part-1"}}}
    assert_receive {:stream_event, %{type: :delta, payload: %{text: "part-2"}}}
  end

  test "混合生命周期噪音事件时仍可完成，并返回正确文本" do
    Application.put_env(:men, :gong_rpc_test_mode, :with_noise_events)

    assert {:ok, payload} =
             GongRPC.start_turn("hello-noise", %{
               request_id: "req-rpc-noise-1",
               session_key: "dingtalk:noise",
               run_id: "run-rpc-noise-1"
             })

    assert payload.text == "rpc noisy ok"
  end

  test "tool.start/tool.end 会映射为结构化 delta 回调（供卡片状态消费）" do
    Application.put_env(:men, :gong_rpc_test_mode, :with_noise_events)
    parent = self()
    callback = fn event -> send(parent, {:stream_event, event}) end

    assert {:ok, payload} =
             GongRPC.start_turn("hello-noise-tool", %{
               request_id: "req-rpc-noise-tool-1",
               session_key: "dingtalk:noise-tool",
               run_id: "run-rpc-noise-tool-1",
               event_callback: callback
             })

    assert payload.text == "rpc noisy ok"

    assert_receive {:stream_event,
                    %{
                      type: :delta,
                      payload: %{text: "", tool_name: "list_directory", tool_status: "start"}
                    }}

    assert_receive {:stream_event, %{type: :delta, payload: %{text: "part-a"}}}

    assert_receive {:stream_event,
                    %{
                      type: :delta,
                      payload: %{text: "", tool_name: "list_directory", tool_status: "end"}
                    }}

    refute_receive {:stream_event,
                    %{type: :delta, payload: %{text: "\n[tool:start] list_directory\n"}}}
  end

  test "会话失效时触发关闭并重建" do
    Application.put_env(:men, :gong_rpc_test_mode, :session_not_found_once)

    assert {:ok, payload} =
             GongRPC.start_turn("hello-rebuild", %{
               request_id: "req-rpc-rebuild-1",
               session_key: "dingtalk:rebuild",
               run_id: "run-rpc-rebuild-1"
             })

    assert payload.text == "rpc rebuilt"
    assert_receive {:rpc_create_session, :session_not_found_once}
    assert_receive {:rpc_close_session, _}
    assert_receive {:rpc_create_session, :session_not_found_once}
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

    Application.put_env(
      :men,
      GongRPC,
      Application.get_env(:men, GongRPC, []) |> Keyword.put(:completion_timeout_ms, 60)
    )

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
