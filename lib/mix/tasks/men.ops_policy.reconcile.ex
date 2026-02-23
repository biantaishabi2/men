defmodule Mix.Tasks.Men.OpsPolicy.Reconcile do
  @moduledoc """
  手动触发一次 ops policy 对账。
  """

  use Mix.Task

  alias Men.Ops.Policy.Sync

  @shortdoc "手动执行 Ops Policy reconcile"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    case Sync.reconcile_now() do
      :ok ->
        Mix.shell().info("ops policy reconcile: ok")

      {:error, reason} ->
        Mix.raise("ops policy reconcile failed: #{inspect(reason)}")
    end
  end
end
