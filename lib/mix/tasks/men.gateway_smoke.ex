defmodule Mix.Tasks.Men.GatewaySmoke do
  @moduledoc """
  网关事件协调 smoke：验证 wake 决策、去重、ETS 回查。
  """

  use Mix.Task

  alias Men.Gateway.DispatchServer
  alias Men.Gateway.ReplStore

  @shortdoc "运行网关事件协调 smoke"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    :ok = ReplStore.reset()

    event = %{
      type: "agent_result",
      source: "agent.agent_a",
      session_key: "smoke-session",
      event_id: "smoke-event-1",
      version: 1,
      ets_keys: ["agent.agent_a.data.result.task_1"],
      payload: %{signal: "result_ready"}
    }

    {first, second} =
      if function_exported?(DispatchServer, :coordinate_event, 3) do
        {:ok, first} = apply(DispatchServer, :coordinate_event, [DispatchServer, event, %{}])
        {:ok, second} = apply(DispatchServer, :coordinate_event, [DispatchServer, event, %{}])
        {first, second}
      else
        Mix.shell().info("coordinate_event/3 不可用，跳过事件协调 smoke")
        {%{envelope: %{wake: false}}, %{store_result: :skipped}}
      end

    ets_lookup_hit =
      case ReplStore.latest_by_ets_keys(["agent.agent_a.data.result.task_1"]) do
        {:ok, _} -> true
        :not_found -> false
      end

    Mix.shell().info("wake_decision=#{first.envelope.wake}")
    Mix.shell().info("duplicate=#{second.store_result == :duplicate}")
    Mix.shell().info("ets_lookup_hit=#{ets_lookup_hit}")
  end
end
