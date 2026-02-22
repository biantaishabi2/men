defmodule Men.Gateway.DispatchServerModeSwitchTest do
  use ExUnit.Case, async: false

  alias Men.Gateway.DispatchServer
  alias Men.Gateway.InboxStore

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, _context),
      do: {:ok, %{text: "ok:" <> prompt, meta: %{source: :mode_test}}}
  end

  defmodule MockEgress do
    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(_target, _message), do: :ok
  end

  setup do
    InboxStore.reset()
    Phoenix.PubSub.subscribe(Men.PubSub, "mode_transitions")
    :ok
  end

  defp start_dispatch_server(opts \\ []) do
    default_opts = [
      name: {:global, {__MODULE__, self(), make_ref()}},
      bridge_adapter: MockBridge,
      egress_adapter: MockEgress,
      session_coordinator_enabled: false,
      mode_state_machine_enabled: true
    ]

    start_supervised!({DispatchServer, Keyword.merge(default_opts, opts)})
  end

  defp dispatch_with_signals(server, request_id, payload, mode_signals) do
    event = %{
      request_id: request_id,
      payload: payload,
      channel: "feishu",
      user_id: "u-mode",
      mode_signals: mode_signals
    }

    DispatchServer.dispatch(server, event)
  end

  test "场景1+2：research->plan->execute 触发事件并带契约字段" do
    server = start_dispatch_server(mode_state_machine_options: %{stable_window_ticks: 3})

    assert {:ok, _} =
             dispatch_with_signals(server, "req-1", "p-1", %{
               blocking_count: 0,
               key_claim_confidence: 0.82,
               graph_change_rate: 0.03
             })

    assert {:ok, _} =
             dispatch_with_signals(server, "req-2", "p-2", %{
               blocking_count: 0,
               key_claim_confidence: 0.82,
               graph_change_rate: 0.02
             })

    assert {:ok, _} =
             dispatch_with_signals(server, "req-3", "p-3", %{
               blocking_count: 0,
               key_claim_confidence: 0.82,
               graph_change_rate: 0.01
             })

    assert_receive {:mode_transitioned, transition_1}
    assert transition_1.from_mode == :research
    assert transition_1.to_mode == :plan
    assert transition_1.reason == :confidence_and_stability_satisfied
    assert is_binary(transition_1.transition_id)
    assert is_binary(transition_1.snapshot_digest)
    assert is_map(transition_1.hysteresis_state)
    assert is_integer(transition_1.cooldown_remaining)

    assert {:ok, _} =
             dispatch_with_signals(server, "req-4", "p-4", %{
               plan_selected: true,
               execute_compilable: true
             })

    assert_receive {:mode_transitioned, transition_2}
    assert transition_2.from_mode == :plan
    assert transition_2.to_mode == :execute
    assert transition_2.reason == :plan_ready_for_execution
  end

  test "场景3：execute->research 回退会生成补链任务并按前提幂等去重" do
    server =
      start_dispatch_server(
        mode_state_machine_mode: :execute,
        mode_state_machine_options: %{cooldown_ticks: 3}
      )

    assert {:ok, _} =
             dispatch_with_signals(server, "req-r-1", "p-r-1", %{
               premise_invalidated: true,
               invalidated_premise_ids: ["premise-1", "premise-1"],
               critical_paths_by_premise: %{"premise-1" => ["path-a", "path-b"]}
             })

    assert_receive {:mode_transitioned, transition}
    assert transition.from_mode == :execute
    assert transition.to_mode == :research
    assert transition.reason == :premise_invalidated
    assert length(transition.inserted_backfill_tasks) == 1

    [task] = transition.inserted_backfill_tasks
    assert task.transition_id == transition.transition_id
    assert task.premise_id == "premise-1"

    assert {:ok, envelope} =
             InboxStore.latest_by_ets_keys(["mode_backfill", transition.transition_id, "premise-1"])

    assert envelope.type == "mode_backfill"
    assert envelope.payload.premise_id == "premise-1"
  end

  test "边界：抖动超限降级为 research-only 并在恢复窗口后恢复" do
    server =
      start_dispatch_server(
        mode_state_machine_options: %{
          stable_window_ticks: 1,
          cooldown_ticks: 0,
          churn_window_ticks: 6,
          churn_max_transitions: 2,
          research_only_recovery_ticks: 2
        }
      )

    assert {:ok, _} =
             dispatch_with_signals(server, "req-s-1", "p-s-1", %{
               blocking_count: 0,
               key_claim_confidence: 0.9,
               graph_change_rate: 0.01
             })

    assert_receive {:mode_transitioned, %{from_mode: :research, to_mode: :plan}}

    assert {:ok, _} =
             dispatch_with_signals(server, "req-s-2", "p-s-2", %{
               plan_selected: true,
               execute_compilable: true
             })

    assert_receive {:mode_transitioned, %{from_mode: :plan, to_mode: :execute}}

    assert {:ok, _} =
             dispatch_with_signals(server, "req-s-3", "p-s-3", %{
               premise_invalidated: true,
               invalidated_premise_ids: ["premise-x"]
             })

    assert_receive {:mode_transitioned, transition_back}
    assert transition_back.to_mode == :research

    assert {:ok, _} =
             dispatch_with_signals(server, "req-s-4", "p-s-4", %{
               blocking_count: 0,
               key_claim_confidence: 0.95,
               graph_change_rate: 0.01
             })

    refute_receive {:mode_transitioned, %{to_mode: :plan}}, 100

    assert {:ok, _} = dispatch_with_signals(server, "req-s-5", "p-s-5", %{})
    assert {:ok, _} = dispatch_with_signals(server, "req-s-6", "p-s-6", %{})

    assert {:ok, _} =
             dispatch_with_signals(server, "req-s-7", "p-s-7", %{
               blocking_count: 0,
               key_claim_confidence: 0.95,
               graph_change_rate: 0.01
             })

    assert_receive {:mode_transitioned, %{from_mode: :research, to_mode: :plan}}
  end

  test "并发 dispatch：状态机上下文推进稳定且回退补链仅入队一次" do
    server =
      start_dispatch_server(
        mode_state_machine_mode: :execute,
        mode_state_machine_options: %{cooldown_ticks: 0}
      )

    1..2
    |> Task.async_stream(
      fn idx ->
        dispatch_with_signals(server, "req-c-#{idx}", "p-c-#{idx}", %{
          premise_invalidated: true,
          invalidated_premise_ids: ["premise-c", "premise-c"],
          critical_paths_by_premise: %{"premise-c" => ["path-a", "path-b"]}
        })
      end,
      ordered: false,
      max_concurrency: 2,
      timeout: 5_000
    )
    |> Enum.each(fn
      {:ok, {:ok, _}} -> :ok
      other -> flunk("unexpected dispatch result: #{inspect(other)}")
    end)

    assert_receive {:mode_transitioned, transition}
    assert transition.from_mode == :execute
    assert transition.to_mode == :research
    assert length(transition.inserted_backfill_tasks) == 1

    refute_receive {:mode_transitioned, %{from_mode: :execute, to_mode: :research}}, 100

    assert {:ok, envelope} =
             InboxStore.latest_by_ets_keys(["mode_backfill", transition.transition_id, "premise-c"])

    assert envelope.payload.premise_id == "premise-c"

    state = :sys.get_state(server)
    assert state.mode_state_machine_mode == :research
    assert state.mode_state_machine_context.tick == 2
  end
end
