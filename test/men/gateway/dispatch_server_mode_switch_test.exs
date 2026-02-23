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

  test "默认建议模式：research 就绪时发布 mode_advised，不强制迁移" do
    server = start_dispatch_server(mode_state_machine_options: %{stable_window_ticks: 2})

    assert {:ok, _} =
             dispatch_with_signals(server, "req-1", "p-1", %{
               blocking_count: 0,
               key_claim_confidence: 0.9,
               graph_change_rate: 0.03,
               execute_compilable: true
             })

    assert {:ok, _} =
             dispatch_with_signals(server, "req-2", "p-2", %{
               blocking_count: 0,
               key_claim_confidence: 0.9,
               graph_change_rate: 0.01,
               execute_compilable: true
             })

    assert_receive {:mode_transitioned, advice}
    assert advice.from_mode == :research
    assert advice.recommended_mode == :execute
    assert advice.reason == :evidence_and_compile_ready

    state = :sys.get_state(server)
    assert state.mode_state_machine_mode == :research
  end

  test "显式采纳建议时，允许 execute 迁移" do
    server =
      start_dispatch_server(
        mode_policy_apply: true,
        mode_state_machine_options: %{stable_window_ticks: 2}
      )

    assert {:ok, _} =
             dispatch_with_signals(server, "req-a-1", "p-a-1", %{
               blocking_count: 0,
               key_claim_confidence: 0.9,
               graph_change_rate: 0.03,
               execute_compilable: true
             })

    assert {:ok, _} =
             dispatch_with_signals(server, "req-a-2", "p-a-2", %{
               blocking_count: 0,
               key_claim_confidence: 0.9,
               graph_change_rate: 0.01,
               execute_compilable: true
             })

    assert_receive {:mode_transitioned, transition}
    assert transition.from_mode == :research
    assert transition.to_mode == :execute

    state = :sys.get_state(server)
    assert state.mode_state_machine_mode == :execute
  end

  test "execute 前提失效时默认只建议回退，不强制迁移" do
    server = start_dispatch_server(mode_state_machine_mode: :execute)

    assert {:ok, _} =
             dispatch_with_signals(server, "req-e-1", "p-e-1", %{
               premise_invalidated: true,
               invalidated_premise_ids: ["premise-1"]
             })

    assert_receive {:mode_transitioned, advice}
    assert advice.from_mode == :execute
    assert advice.recommended_mode == :research
    assert advice.reason == :premise_invalidated

    refute_receive {:mode_transitioned, _}, 100

    state = :sys.get_state(server)
    assert state.mode_state_machine_mode == :execute
  end

  test "采纳回退建议时，execute->research 迁移并生成 backfill" do
    server =
      start_dispatch_server(
        mode_policy_apply: true,
        mode_state_machine_mode: :execute,
        mode_state_machine_options: %{cooldown_ticks: 0}
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
    assert length(transition.inserted_backfill_tasks) == 2

    assert {:ok, envelope} =
             InboxStore.latest_by_ets_keys([
               "mode_backfill",
               transition.transition_id,
               "premise-1",
               "path-a"
             ])

    assert envelope.payload.premise_id == "premise-1"
  end
end
