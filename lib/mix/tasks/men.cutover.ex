defmodule Mix.Tasks.Men.Cutover do
  @moduledoc """
  cutover 运维命令。

  用法示例：
    mix men.cutover status
    mix men.cutover enable
    mix men.cutover disable
    mix men.cutover whitelist --set tenantA,tenantB
    mix men.cutover rollback
    mix men.cutover drill
  """

  use Mix.Task

  @shortdoc "管理 men->zcpg cutover"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["status"] ->
        print_status()

      ["enable"] ->
        update_cfg(fn cfg -> Keyword.put(cfg, :enabled, true) end)
        Mix.shell().info("cutover enabled")
        print_status()

      ["disable"] ->
        update_cfg(fn cfg -> Keyword.put(cfg, :enabled, false) end)
        Mix.shell().info("cutover disabled")
        print_status()

      ["whitelist", "--set", csv] ->
        tenants =
          csv
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        update_cfg(fn cfg -> Keyword.put(cfg, :tenant_whitelist, tenants) end)
        Mix.shell().info("cutover whitelist updated")
        print_status()

      ["rollback"] ->
        update_cfg(fn cfg ->
          cfg
          |> Keyword.put(:enabled, false)
          |> Keyword.put(:tenant_whitelist, [])
        end)

        Mix.shell().info("rollback done: cutover disabled and whitelist cleared")
        print_status()

      ["drill"] ->
        Mix.shell().info(
          "rollback drill: simulated at #{DateTime.utc_now() |> DateTime.to_iso8601()}"
        )

      _ ->
        Mix.shell().error("unknown command")
        Mix.shell().info("expected: status|enable|disable|whitelist --set <csv>|rollback|drill")
    end
  end

  defp update_cfg(fun) do
    cfg = Application.get_env(:men, :zcpg_cutover, [])
    Application.put_env(:men, :zcpg_cutover, fun.(cfg))
  end

  defp print_status do
    cfg = Application.get_env(:men, :zcpg_cutover, [])

    Mix.shell().info("enabled=#{Keyword.get(cfg, :enabled, false)}")
    Mix.shell().info("tenant_whitelist=#{inspect(Keyword.get(cfg, :tenant_whitelist, []))}")
    Mix.shell().info("env_override=#{Keyword.get(cfg, :env_override, false)}")
    Mix.shell().info("timeout_ms=#{Keyword.get(cfg, :timeout_ms, 8_000)}")
    Mix.shell().info("breaker=#{inspect(Keyword.get(cfg, :breaker, []))}")
  end
end
