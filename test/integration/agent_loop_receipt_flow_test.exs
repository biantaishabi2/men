defmodule Men.Integration.AgentLoopReceiptFlowTest do
  use ExUnit.Case, async: false

  alias Men.Gateway.DispatchServer
  alias Men.Gateway.EventBus
  alias Men.Gateway.Receipt
  alias Men.Gateway.ReplStore

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      notify({:bridge_prompt, prompt, context})

      payload = decode_base_prompt(prompt)
      scenario = Map.get(payload, "scenario") || Map.get(payload, :scenario)

      response =
        case scenario do
          "success_action" ->
            %{
              text: "ok-success",
              actions: [%{action_id: "act-success", name: "tool.echo", params: %{v: 1}}],
              meta: %{scenario: scenario}
            }

          "retryable_fail" ->
            %{
              text: "ok-retry",
              actions: [%{action_id: "act-retry", name: "tool.retry", params: %{v: 2}}],
              meta: %{scenario: scenario}
            }

          "non_retryable_fail" ->
            %{
              text: "ok-non-retry",
              actions: [%{action_id: "act-fail", name: "tool.fail", params: %{v: 3}}],
              meta: %{scenario: scenario}
            }

          _ ->
            %{text: "ok-none", meta: %{scenario: scenario}}
        end

      {:ok, response}
    end

    defp decode_base_prompt(prompt) do
      prompt
      |> String.split("\n\n[HUD]\n", parts: 2)
      |> List.first()
      |> then(fn base_prompt ->
        case Jason.decode(base_prompt) do
          {:ok, decoded} -> decoded
          _ -> %{"raw" => base_prompt}
        end
      end)
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :agent_loop_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule MockEgress do
    import Kernel, except: [send: 2]

    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(target, message) do
      if pid = Application.get_env(:men, :agent_loop_test_pid) do
        Kernel.send(pid, {:egress_called, target, message})
      end

      :ok
    end
  end

  setup do
    Application.put_env(:men, :agent_loop_test_pid, self())

    topic = "agent_loop_topic_#{System.unique_integer([:positive, :monotonic])}"
    :ok = EventBus.subscribe(topic)

    opts = [
      state_table: :"agent_loop_state_#{System.unique_integer([:positive, :monotonic])}",
      dedup_table: :"agent_loop_dedup_#{System.unique_integer([:positive, :monotonic])}",
      inbox_table: :"agent_loop_inbox_#{System.unique_integer([:positive, :monotonic])}",
      scope_table: :"agent_loop_scope_#{System.unique_integer([:positive, :monotonic])}"
    ]

    ReplStore.reset(opts)

    dispatcher = fn action, _context, _opts ->
      case action.action_id do
        "act-retry" -> {:error, %{code: "TEMP_UNAVAILABLE", message: "retry", retryable: true}}
        "act-fail" -> {:error, %{code: "PERM_FAILED", message: "failed", retryable: false}}
        _ -> {:ok, %{done: true, action_id: action.action_id}}
      end
    end

    server_name = {:global, {__MODULE__, self(), make_ref()}}

    server =
      start_supervised!(
        {DispatchServer,
         name: server_name,
         bridge_adapter: MockBridge,
         egress_adapter: MockEgress,
         session_coordinator_enabled: false,
         agent_loop_enabled: true,
         prompt_frame_injection_enabled: true,
         frame_budget_tokens: 16_000,
         frame_budget_messages: 20,
         receipt_recent_limit: 20,
         event_bus_topic: topic,
         repl_store_opts: opts,
         action_dispatcher: dispatcher}
      )

    on_exit(fn ->
      Application.delete_env(:men, :agent_loop_test_pid)
    end)

    %{server: server, topic: topic, repl_opts: opts}
  end

  test "成功动作: action->receipt 成功并回流下一轮", %{server: server, repl_opts: repl_opts} do
    event_1 = %{
      request_id: "req-success-1",
      run_id: "run-success-1",
      payload: %{scenario: "success_action", messages: [%{role: "user", content: "hello"}]},
      channel: "feishu",
      user_id: "u-success"
    }

    assert {:ok, _} = DispatchServer.dispatch(server, event_1)
    assert_receive {:gateway_event, %{type: "action_receipt", action_id: "act-success"}}

    key =
      Receipt.receipt_key(
        "feishu:u-success",
        Receipt.new(%{run_id: "run-success-1", action_id: "act-success"})
      )

    assert {:ok, _row} =
             ReplStore.get(
               %{role: :system, session_key: "feishu:u-success"},
               key,
               Keyword.merge(repl_opts,
                 policy: %{acl: %{"system" => %{"read" => [""], "write" => [""]}}}
               )
             )

    event_2 = %{
      request_id: "req-success-2",
      payload: %{scenario: "no_action", messages: [%{role: "user", content: "next"}]},
      channel: "feishu",
      user_id: "u-success"
    }

    assert {:ok, _} = DispatchServer.dispatch(server, event_2)
    assert_receive {:bridge_prompt, prompt, %{request_id: "req-success-2"}}
    assert String.contains?(prompt, "[HUD]")
    assert String.contains?(prompt, "act-success")
  end

  test "可重试失败: retryable=true 且状态可观测", %{server: server} do
    event_1 = %{
      request_id: "req-retry-1",
      run_id: "run-retry-1",
      payload: %{scenario: "retryable_fail", messages: [%{role: "user", content: "retry"}]},
      channel: "feishu",
      user_id: "u-retry"
    }

    assert {:ok, _} = DispatchServer.dispatch(server, event_1)

    assert_receive {:gateway_event,
                    %{type: "action_receipt", action_id: "act-retry", receipt: receipt}}

    assert receipt["retryable"] == true or receipt[:retryable] == true

    event_2 = %{
      request_id: "req-retry-2",
      payload: %{scenario: "no_action", messages: [%{role: "user", content: "next"}]},
      channel: "feishu",
      user_id: "u-retry"
    }

    assert {:ok, _} = DispatchServer.dispatch(server, event_2)
    assert_receive {:bridge_prompt, prompt, %{request_id: "req-retry-2"}}
    assert String.contains?(prompt, "act-retry")
  end

  test "不可重试失败: retryable=false 且不中断主循环", %{server: server} do
    event_1 = %{
      request_id: "req-fail-1",
      run_id: "run-fail-1",
      payload: %{scenario: "non_retryable_fail", messages: [%{role: "user", content: "boom"}]},
      channel: "feishu",
      user_id: "u-fail"
    }

    assert {:ok, result} = DispatchServer.dispatch(server, event_1)
    assert result.request_id == "req-fail-1"

    event_2 = %{
      request_id: "req-fail-2",
      payload: %{scenario: "no_action", messages: [%{role: "user", content: "next"}]},
      channel: "feishu",
      user_id: "u-fail"
    }

    assert {:ok, _} = DispatchServer.dispatch(server, event_2)
    assert_receive {:bridge_prompt, prompt, %{request_id: "req-fail-2"}}
    refute String.contains?(prompt, "\"pending_actions\":[{\"action_id\":\"act-fail\"")
    assert String.contains?(prompt, "\"action_id\":\"act-fail\"")
  end

  test "重复回执幂等: 同 run_id+action_id 不重复生效", %{server: server} do
    attrs = %{
      session_key: "feishu:u-idem",
      run_id: "run-idem-1",
      action_id: "act-idem",
      status: :ok,
      code: "OK",
      message: "done",
      data: %{},
      retryable: false,
      ts: System.system_time(:millisecond)
    }

    assert {:ok, %{status: :stored}} = DispatchServer.push_receipt(server, attrs)
    assert_receive {:gateway_event, %{type: "action_receipt", action_id: "act-idem"}}

    assert {:ok, %{status: :duplicate}} = DispatchServer.push_receipt(server, attrs)
    refute_receive {:gateway_event, %{type: "action_receipt", action_id: "act-idem"}}
  end

  test "并发重复回执幂等: 同 run_id+action_id 并发写入仅一次生效", %{server: server} do
    attrs = %{
      session_key: "feishu:u-idem-concurrent",
      run_id: "run-idem-concurrent-1",
      action_id: "act-idem-concurrent",
      status: :ok,
      code: "OK",
      message: "done",
      data: %{},
      retryable: false,
      ts: System.system_time(:millisecond)
    }

    results =
      1..20
      |> Task.async_stream(
        fn _ -> DispatchServer.push_receipt(server, attrs) end,
        max_concurrency: 20,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    stored_count = Enum.count(results, &match?({:ok, %{status: :stored}}, &1))
    duplicate_count = Enum.count(results, &match?({:ok, %{status: :duplicate}}, &1))

    assert stored_count == 1
    assert duplicate_count == 19
    assert_receive {:gateway_event, %{type: "action_receipt", action_id: "act-idem-concurrent"}}
    refute_receive {:gateway_event, %{type: "action_receipt", action_id: "act-idem-concurrent"}}
  end

  test "pending 按 run_id+action_id 隔离，ack 不应跨 run 误删", %{server: server} do
    event_1 = %{
      request_id: "req-collision-1",
      run_id: "run-collision-1",
      payload: %{scenario: "retryable_fail", messages: [%{role: "user", content: "turn1"}]},
      channel: "feishu",
      user_id: "u-collision"
    }

    event_2 = %{
      request_id: "req-collision-2",
      run_id: "run-collision-2",
      payload: %{scenario: "retryable_fail", messages: [%{role: "user", content: "turn2"}]},
      channel: "feishu",
      user_id: "u-collision"
    }

    assert {:ok, _} = DispatchServer.dispatch(server, event_1)
    assert {:ok, _} = DispatchServer.dispatch(server, event_2)

    assert {:ok, %{status: ack_status}} =
             DispatchServer.push_receipt(server, %{
               session_key: "feishu:u-collision",
               run_id: "run-collision-1",
               action_id: "act-retry",
               status: :failed,
               code: "PERM_ACK",
               message: "manual-ack",
               data: %{},
               retryable: false,
               ts: System.system_time(:millisecond)
             })

    assert ack_status in [:stored, :duplicate]

    event_3 = %{
      request_id: "req-collision-3",
      payload: %{scenario: "no_action", messages: [%{role: "user", content: "turn3"}]},
      channel: "feishu",
      user_id: "u-collision"
    }

    assert {:ok, _} = DispatchServer.dispatch(server, event_3)
    assert_receive {:bridge_prompt, prompt, %{request_id: "req-collision-3"}}

    [_base_prompt, hud_payload] = String.split(prompt, "\n\n[HUD]\n", parts: 2)
    assert {:ok, hud_map} = Jason.decode(hud_payload)
    pending_actions = get_in(hud_map, ["frame", "pending_actions"]) || []

    refute Enum.any?(pending_actions, fn item ->
             item["run_id"] == "run-collision-1" and item["action_id"] == "act-retry"
           end)

    assert Enum.any?(pending_actions, fn item ->
             item["run_id"] == "run-collision-2" and item["action_id"] == "act-retry"
           end)
  end

  test "push_receipt 缺失 run_id/action_id 应返回错误且不落库", %{server: server} do
    base = %{
      session_key: "feishu:u-invalid-receipt",
      status: :ok,
      code: "OK",
      message: "done",
      data: %{},
      retryable: false,
      ts: System.system_time(:millisecond)
    }

    assert {:error, {:invalid_required_field, :run_id}} =
             DispatchServer.push_receipt(server, Map.delete(base, :run_id))

    assert {:error, {:invalid_required_field, :action_id}} =
             DispatchServer.push_receipt(server, Map.put(base, :run_id, "run-invalid-1"))
  end

  test "延迟回流: 回执晚到可被下一轮消费", %{server: server} do
    event_1 = %{
      request_id: "req-delay-1",
      payload: %{scenario: "no_action", messages: [%{role: "user", content: "turn1"}]},
      channel: "feishu",
      user_id: "u-delay"
    }

    assert {:ok, _} = DispatchServer.dispatch(server, event_1)

    attrs = %{
      session_key: "feishu:u-delay",
      run_id: "run-delay-1",
      action_id: "act-delay",
      status: :ok,
      code: "OK",
      message: "late",
      data: %{late: true},
      retryable: false,
      ts: System.system_time(:millisecond)
    }

    assert {:ok, %{status: :stored}} = DispatchServer.push_receipt(server, attrs)

    event_2 = %{
      request_id: "req-delay-2",
      payload: %{scenario: "no_action", messages: [%{role: "user", content: "turn2"}]},
      channel: "feishu",
      user_id: "u-delay"
    }

    assert {:ok, _} = DispatchServer.dispatch(server, event_2)
    assert_receive {:bridge_prompt, prompt, %{request_id: "req-delay-2"}}
    assert String.contains?(prompt, "act-delay")
  end

  test "非 action 兼容: 关闭注入时保留旧 prompt 语义" do
    server_name = {:global, {__MODULE__, :legacy, self(), make_ref()}}

    legacy_server =
      start_supervised!(
        Supervisor.child_spec(
          {DispatchServer,
           name: server_name,
           bridge_adapter: MockBridge,
           egress_adapter: MockEgress,
           session_coordinator_enabled: false,
           agent_loop_enabled: true,
           prompt_frame_injection_enabled: false},
          id: {:legacy_dispatch_server, self(), make_ref()}
        )
      )

    event = %{
      request_id: "req-legacy-1",
      payload: "plain-legacy",
      channel: "feishu",
      user_id: "u-legacy"
    }

    assert {:ok, _} = DispatchServer.dispatch(legacy_server, event)
    assert_receive {:bridge_prompt, "plain-legacy", %{request_id: "req-legacy-1"}}
  end
end
