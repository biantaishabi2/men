defmodule Men.RuntimeBridge.ZcpgRPCTest do
  use ExUnit.Case, async: false

  alias Men.RuntimeBridge.{Bridge, Error, Request, Response, ZcpgRPC}

  defmodule MockTransport do
    @behaviour Men.RuntimeBridge.ZcpgRPC.HttpTransport

    @impl true
    def request(:post, url, headers, body, opts) do
      if pid = Application.get_env(:men, :zcpg_rpc_test_pid) do
        send(pid, {:zcpg_transport_request, url, headers, body, opts})
      end

      case Application.get_env(:men, :zcpg_rpc_test_mode, {:ok, 200, %{"text" => "ok"}}) do
        {:ok, status, response_body} ->
          {:ok, %{status: status, body: response_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defmodule MockRollbackBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      {:ok,
       %{
         text: "rollback:" <> prompt,
         meta: %{
           source: :rollback_bridge,
           request_id: Map.get(context, :request_id),
           session_key: Map.get(context, :session_key),
           run_id: Map.get(context, :run_id)
         }
       }}
    end
  end

  defmodule MockLegacyErrorBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, _context) do
      case prompt do
        "keep-retryable-false" ->
          {:error,
           %{
             code: "runtime_error",
             message: "upstream failed",
             details: %{status: 502, retryable: false}
           }}

        "string-details" ->
          {:error,
           %{
             "code" => "runtime_error",
             "message" => "unprocessable",
             "details" => %{"status" => 422}
           }}

        "map-message" ->
          {:error,
           %{
             code: "runtime_error",
             message: %{"reason" => "bad payload"},
             details: %{status: 500}
           }}
      end
    end
  end

  defmodule DeterministicTransport do
    @behaviour Men.RuntimeBridge.ZcpgRPC.HttpTransport

    @impl true
    def request(:post, _url, _headers, body, _opts) do
      %{"payload" => %{"prompt" => prompt}} = Jason.decode!(body)

      case prompt do
        "timeout" ->
          {:ok, %{status: 504, body: %{"message" => "gateway timeout"}}}

        "invalid" ->
          {:ok, %{status: 422, body: %{"error" => "unprocessable"}}}

        _ ->
          {:ok,
           %{status: 200, body: %{"text" => "ok:" <> prompt, "meta" => %{"source" => "det"}}}}
      end
    end
  end

  setup do
    original_bridge_runtime = Application.get_env(:men, :runtime_bridge, [])
    original_zcpg_runtime = Application.get_env(:men, ZcpgRPC, [])

    Application.put_env(:men, :zcpg_rpc_test_pid, self())

    Application.put_env(:men, ZcpgRPC,
      base_url: "http://example.test",
      path: "/internal/agent_gateway/v1/execute",
      token: "test-token",
      timeout: 321,
      transport: MockTransport
    )

    Application.put_env(:men, :runtime_bridge,
      bridge_impl: ZcpgRPC,
      bridge_v1_enabled: true,
      timeout_ms: 30_000
    )

    on_exit(fn ->
      Application.put_env(:men, :runtime_bridge, original_bridge_runtime)
      Application.put_env(:men, ZcpgRPC, original_zcpg_runtime)
      Application.delete_env(:men, :zcpg_rpc_test_mode)
      Application.delete_env(:men, :zcpg_rpc_test_pid)
    end)

    :ok
  end

  test "正常返回 text/meta: Bridge.prompt 返回统一 ok 结构" do
    Application.put_env(
      :men,
      :zcpg_rpc_test_mode,
      {:ok, 200, %{"text" => "hi", "meta" => %{"model" => "x"}}}
    )

    request = %Request{
      runtime_id: "zcpg",
      session_id: "s1",
      payload: "hello",
      opts: %{request_id: "req-1", run_id: "run-1"}
    }

    assert {:ok, %Response{} = response} = Bridge.prompt(request, adapter: ZcpgRPC)
    assert response.payload == "hi"
    assert response.metadata["model"] == "x"

    assert_receive {:zcpg_transport_request, _url, headers, body, request_opts}
    assert {"authorization", "Bearer test-token"} in headers
    assert request_opts[:timeout_ms] == 321

    decoded = Jason.decode!(body)
    assert decoded["run_id"] == "run-1"
    assert decoded["tenant_id"] == "default_tenant"
    assert decoded["trace_id"] == "req-1"
    assert decoded["agent_id"] == "voucher_agent"
    assert decoded["timeout_ms"] == 321
    assert decoded["payload"]["prompt"] == "hello"
    assert decoded["payload"]["raw_input"] == "hello"
    assert decoded["payload"]["request_id"] == "req-1"
    assert decoded["payload"]["session_key"] == "s1"
  end

  test "网关超时映射: 网络超时与 504 都返回 timeout+retryable=true" do
    request = build_prompt_request("timeout-1")

    Application.put_env(:men, :zcpg_rpc_test_mode, {:error, :timeout})
    assert {:error, %Error{} = error} = Bridge.prompt(request, adapter: ZcpgRPC)
    assert error.code == :timeout
    assert error.retryable == true

    Application.put_env(:men, :zcpg_rpc_test_mode, {:ok, 504, ~s({"message":"gateway timeout"})})
    assert {:error, %Error{} = error_504} = Bridge.prompt(request, adapter: ZcpgRPC)
    assert error_504.code == :timeout
    assert error_504.retryable == true
  end

  test "契约错误映射: 400/422/坏 JSON/缺失 text/非 map body -> invalid_argument" do
    request = build_prompt_request("invalid-1")

    invalid_cases = [
      {:ok, 400, %{"error" => "bad request"}},
      {:ok, 422, %{"error" => "unprocessable"}},
      {:ok, 200, "not-json"},
      {:ok, 200, ~s(["array-body"])},
      {:ok, 200, %{"meta" => %{}}},
      {:ok, 200, %{"text" => "ok", "meta" => "not-map"}},
      {:ok, 200, 123}
    ]

    Enum.each(invalid_cases, fn mode ->
      Application.put_env(:men, :zcpg_rpc_test_mode, mode)
      assert {:error, %Error{} = error} = Bridge.prompt(request, adapter: ZcpgRPC)
      assert error.code == :invalid_argument
      assert error.retryable == false
    end)
  end

  test "关键边界: 空 text 合法且 meta 缺失默认 %{}" do
    request = build_prompt_request("edge-1")

    Application.put_env(
      :men,
      :zcpg_rpc_test_mode,
      {:ok, 200, %{"text" => "", "meta" => %{"trace_id" => "t-1"}}}
    )

    assert {:ok, %Response{} = empty_text_response} = Bridge.prompt(request, adapter: ZcpgRPC)
    assert empty_text_response.payload == ""
    assert empty_text_response.metadata["trace_id"] == "t-1"

    Application.put_env(:men, :zcpg_rpc_test_mode, {:ok, 200, %{"text" => "no-meta"}})
    assert {:ok, %Response{} = no_meta_response} = Bridge.prompt(request, adapter: ZcpgRPC)
    assert no_meta_response.payload == "no-meta"
    assert no_meta_response.metadata == %{}
  end

  test "非 2xx 细分: 5xx 为 runtime_error，其它状态为 transport_error" do
    request = build_prompt_request("status-1")

    Application.put_env(
      :men,
      :zcpg_rpc_test_mode,
      {:ok, 502, %{"message" => "upstream bad gateway"}}
    )

    assert {:error, %Error{} = runtime_error} = Bridge.prompt(request, adapter: ZcpgRPC)
    assert runtime_error.code == :runtime_error
    assert runtime_error.retryable == true

    Application.put_env(:men, :zcpg_rpc_test_mode, {:ok, 429, %{"message" => "rate limit"}})
    assert {:error, %Error{} = transport_error} = Bridge.prompt(request, adapter: ZcpgRPC)
    assert transport_error.code == :transport_error
    assert transport_error.retryable == true
  end

  test "灰度切换与回滚: 同入口可切换 bridge_impl 并恢复行为" do
    Application.put_env(
      :men,
      :zcpg_rpc_test_mode,
      {:ok, 200, %{"text" => "zcpg-ok", "meta" => %{}}}
    )

    Application.put_env(:men, :runtime_bridge, bridge_impl: ZcpgRPC, bridge_v1_enabled: false)

    assert {:ok, zcpg_payload} =
             Bridge.start_turn("hello", %{
               request_id: "req-s",
               session_key: "sess-s",
               run_id: "run-s"
             })

    assert zcpg_payload.text == "zcpg-ok"

    Application.put_env(:men, :runtime_bridge,
      bridge_impl: MockRollbackBridge,
      bridge_v1_enabled: false
    )

    assert {:ok, rollback_payload} =
             Bridge.start_turn("hello", %{
               request_id: "req-s",
               session_key: "sess-s",
               run_id: "run-s"
             })

    assert rollback_payload.text == "rollback:hello"
    assert rollback_payload.meta.source == :rollback_bridge
  end

  test "并发请求不依赖全局 mode: 多请求并行映射稳定" do
    prompts = ["ok-1", "ok-2", "timeout", "invalid", "ok-3", "ok-4"]

    results =
      prompts
      |> Task.async_stream(
        fn prompt ->
          request = %Request{
            runtime_id: "zcpg",
            session_id: "sess-concurrent",
            payload: prompt,
            opts: %{request_id: "req-" <> prompt, run_id: "run-" <> prompt}
          }

          Bridge.prompt(request, adapter: ZcpgRPC, transport: DeterministicTransport)
        end,
        ordered: false,
        max_concurrency: 6,
        timeout: 2_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %Response{}}, &1)) == 4
    assert Enum.any?(results, &match?({:error, %Error{code: :timeout, retryable: true}}, &1))

    assert Enum.any?(
             results,
             &match?({:error, %Error{code: :invalid_argument, retryable: false}}, &1)
           )
  end

  test "v1->legacy timeout 保真: bridge_v1_enabled=true 时保留 timeout+retryable" do
    request = build_prompt_request("timeout")

    assert {:error, payload} =
             Bridge.start_turn(
               "timeout",
               %{request_id: "req-v1", session_key: "sess-v1", run_id: "run-v1"},
               adapter: ZcpgRPC,
               transport: DeterministicTransport,
               bridge_v1_enabled: true
             )

    assert payload.type == :timeout
    assert payload.code == "timeout"
    assert payload.details.retryable == true

    # 确认同语义在 v1 原子接口下仍是 timeout。
    assert {:error, %Error{code: :timeout, retryable: true}} =
             Bridge.prompt(request, adapter: ZcpgRPC, transport: DeterministicTransport)
  end

  test "details.retryable=false 保真: 不被兜底推断覆盖" do
    request = build_prompt_request("keep-retryable-false")

    assert {:error, %Error{} = error} = Bridge.prompt(request, adapter: MockLegacyErrorBridge)
    assert error.code == :runtime_error
    assert error.retryable == false
  end

  test "legacy 错误 message 为 map 时归一化不抛异常" do
    request = build_prompt_request("map-message")

    assert {:error, %Error{} = error} = Bridge.prompt(request, adapter: MockLegacyErrorBridge)
    assert error.code == :runtime_error
    assert is_map(error.message)
    assert error.retryable == true
  end

  test "legacy 错误读取 string-key details 参与优先级归一化" do
    request = build_prompt_request("string-details")

    assert {:error, %Error{} = error} = Bridge.prompt(request, adapter: MockLegacyErrorBridge)
    assert error.code == :invalid_argument
    assert error.retryable == false
  end

  defp build_prompt_request(prompt) do
    %Request{
      runtime_id: "zcpg",
      session_id: "s-contract",
      payload: prompt,
      opts: %{request_id: "req-contract", run_id: "run-contract"}
    }
  end
end
