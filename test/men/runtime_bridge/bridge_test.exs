defmodule Men.RuntimeBridge.BridgeTest do
  use ExUnit.Case, async: true

  alias Men.RuntimeBridge.{Bridge, Error, ErrorResponse, Request, Response}

  defmodule MockRuntimeBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def open(%Request{} = request, _opts) do
      notify({:open_called, request})
      {:ok, %Response{runtime_id: request.runtime_id, session_id: request.session_id, payload: :opened, metadata: %{source: :new}}}
    end

    @impl true
    def get(%Request{} = request, _opts) do
      notify({:get_called, request})
      {:ok, %Response{runtime_id: request.runtime_id, session_id: request.session_id, payload: %{status: :active}, metadata: %{source: :new}}}
    end

    @impl true
    def prompt(%Request{payload: "missing"} = request, _opts) do
      notify({:prompt_called, request})

      {:error,
       %Error{
         code: :session_not_found,
         message: "runtime session missing",
         retryable: true,
         context: %{source: :new}
       }}
    end

    def prompt(%Request{} = request, _opts) do
      notify({:prompt_called, request})
      {:ok, %Response{runtime_id: request.runtime_id, session_id: request.session_id, payload: "runtime-ok", metadata: %{source: :new}}}
    end

    @impl true
    def close(%Request{} = request, _opts) do
      notify({:close_called, request})
      {:ok, %Response{runtime_id: request.runtime_id, session_id: request.session_id, payload: :closed, metadata: %{source: :new}}}
    end

    @impl true
    def call(%Request{} = request, _opts) do
      notify({:legacy_call_called, request})

      {:ok,
       %Response{
         runtime_id: request.runtime_id,
         session_id: request.session_id,
         payload: "legacy-call-ok",
         metadata: %{source: :legacy}
       }}
    end

    @impl true
    def start_turn(prompt, context) do
      notify({:legacy_start_turn_called, prompt, context})
      {:ok, %{text: "legacy:" <> prompt, meta: %{source: :legacy}}}
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :runtime_bridge_test_pid) do
        send(pid, message)
      end

      :ok
    end
  end

  defmodule LegacyOnlyBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(_prompt, _context) do
      {:error, %{code: "NEW_REMOTE_ERROR", message: "legacy failed", details: %{source: :legacy_only}}}
    end
  end

  defmodule StartTurnOnlyBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      notify({:start_turn_only_called, prompt, context})
      {:ok, %{text: prompt, meta: %{source: :start_turn_only}}}
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :runtime_bridge_test_pid) do
        send(pid, message)
      end

      :ok
    end
  end

  setup do
    original_runtime_bridge = Application.get_env(:men, :runtime_bridge, [])
    Application.put_env(:men, :runtime_bridge_test_pid, self())

    Application.put_env(:men, :runtime_bridge,
      original_runtime_bridge
      |> Keyword.put(:bridge_impl, MockRuntimeBridge)
      |> Keyword.put(:bridge_v1_enabled, false)
      |> Keyword.put(:timeout_ms, 30_000)
    )

    on_exit(fn ->
      Application.put_env(:men, :runtime_bridge, original_runtime_bridge)
      Application.delete_env(:men, :runtime_bridge_test_pid)
    end)

    :ok
  end

  test "Request/Response/Error 结构体可构造" do
    request = %Request{runtime_id: "gong", session_id: "sess-1", payload: "hello", opts: %{trace: "t1"}, timeout_ms: 2_000}
    response = %Response{runtime_id: "gong", session_id: "sess-1", payload: "done", metadata: %{token: "x"}}
    error = %Error{code: :runtime_error, message: "failed", retryable: false, context: %{}}

    assert request.runtime_id == "gong"
    assert request.session_id == "sess-1"
    assert request.opts == %{trace: "t1"}
    assert response.payload == "done"
    assert error.code == :runtime_error
  end

  test "open/get/prompt/close 使用新原子接口" do
    request = %Request{runtime_id: "gong", session_id: "sess-2", payload: "ok"}

    assert {:ok, %Response{payload: :opened}} = Bridge.open(request)
    assert_receive {:open_called, %Request{session_id: "sess-2"}}

    assert {:ok, %Response{payload: %{status: :active}}} = Bridge.get(request)
    assert_receive {:get_called, %Request{session_id: "sess-2"}}

    assert {:ok, %Response{payload: "runtime-ok"}} = Bridge.prompt(request)
    assert_receive {:prompt_called, %Request{payload: "ok"}}

    assert {:ok, %Response{payload: :closed}} = Bridge.close(request)
    assert_receive {:close_called, %Request{session_id: "sess-2"}}
  end

  test "deprecated start_turn 默认走旧路径" do
    assert {:ok, %{text: "legacy:hello"}} = Bridge.start_turn("hello", %{session_key: "sess-3"})
    assert_receive {:legacy_start_turn_called, "hello", %{session_key: "sess-3"}}
    refute_receive {:prompt_called, _}
  end

  test "feature flag 打开后 deprecated start_turn 分流到新路径" do
    Application.put_env(
      :men,
      :runtime_bridge,
      Application.get_env(:men, :runtime_bridge, []) |> Keyword.put(:bridge_v1_enabled, true)
    )

    assert {:ok, payload} = Bridge.start_turn("hello", %{session_key: "sess-4", request_id: "req-4"})
    assert payload.text == "runtime-ok"
    assert payload.meta.source == :new

    assert_receive {:prompt_called, %Request{session_id: "sess-4", payload: "hello"}}
    refute_receive {:legacy_start_turn_called, _, _}
  end

  test "session_not_found 语义稳定并可用于上层重建" do
    request = %Request{runtime_id: "gong", session_id: "sess-missing", payload: "missing"}

    assert {:error, %Error{code: :session_not_found, retryable: true}} = Bridge.prompt(request)

    Application.put_env(
      :men,
      :runtime_bridge,
      Application.get_env(:men, :runtime_bridge, []) |> Keyword.put(:bridge_v1_enabled, true)
    )

    assert {:error, error_payload} = Bridge.start_turn("missing", %{session_key: "sess-missing"})
    assert error_payload.code == "session_not_found"
  end

  test "deprecated call 根据 feature flag 分流" do
    request = %Request{runtime_id: "gong", session_id: "sess-5", payload: "ok"}

    assert {:ok, %Response{payload: "legacy-call-ok"}} = Bridge.call(request)
    assert_receive {:legacy_call_called, %Request{session_id: "sess-5"}}

    Application.put_env(
      :men,
      :runtime_bridge,
      Application.get_env(:men, :runtime_bridge, []) |> Keyword.put(:bridge_v1_enabled, true)
    )

    assert {:ok, %Response{payload: "runtime-ok"}} = Bridge.call(request)
    assert_receive {:prompt_called, %Request{session_id: "sess-5"}}
  end

  test "deprecated call 在新路径下映射 ErrorResponse" do
    request = %Request{runtime_id: "gong", session_id: "sess-6", payload: "missing"}

    Application.put_env(
      :men,
      :runtime_bridge,
      Application.get_env(:men, :runtime_bridge, []) |> Keyword.put(:bridge_v1_enabled, true)
    )

    assert {:error, %ErrorResponse{} = error_response} = Bridge.call(request)
    assert error_response.code == "session_not_found"
    assert error_response.reason == "runtime session missing"
  end

  test "deprecated call 在 flag 关闭且 adapter 无 call/2 时不走新路径 fallback" do
    request = %Request{runtime_id: "gong", session_id: "sess-fallback", payload: "hello"}

    assert {:error, %ErrorResponse{} = error_response} =
             Bridge.call(request, adapter: StartTurnOnlyBridge, bridge_v1_enabled: false)

    assert error_response.code == "unsupported_operation"
    assert error_response.reason == "adapter does not implement call/2"
    refute_receive {:start_turn_only_called, _, _}
  end

  test "legacy start_turn 字符串错误码会安全降级，避免动态 atom" do
    request = %Request{runtime_id: "gong", session_id: "sess-legacy", payload: "hello"}

    assert {:error, %Error{} = error} = Bridge.prompt(request, adapter: LegacyOnlyBridge)
    assert error.code == :runtime_error
    assert error.context == %{source: :legacy_only}
  end
end
