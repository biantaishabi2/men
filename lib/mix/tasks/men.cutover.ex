defmodule Mix.Tasks.Men.Cutover do
  @moduledoc """
  cutover 运维命令。

  用法示例：
    mix men.cutover --status
    mix men.cutover --enable
    mix men.cutover --disable
    mix men.cutover --set-whitelist tenantA,tenantB
    mix men.cutover --rollback
    mix men.cutover --drill
  """

  use Mix.Task

  @shortdoc "管理 men->zcpg cutover"
  @switches [
    status: :boolean,
    enable: :boolean,
    disable: :boolean,
    rollback: :boolean,
    drill: :boolean,
    set_whitelist: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      invalid_usage!("invalid arguments")
    end

    action_count =
      Enum.count(
        [opts[:status], opts[:enable], opts[:disable], opts[:rollback], opts[:drill]],
        & &1
      ) +
        if(is_binary(opts[:set_whitelist]), do: 1, else: 0)

    cond do
      action_count == 0 ->
        invalid_usage!("missing action")

      action_count > 1 ->
        invalid_usage!("only one action is allowed")

      opts[:status] ->
        print_status()

      opts[:enable] ->
        update_cfg(fn cfg -> Keyword.put(cfg, :enabled, true) end)
        Mix.shell().info("cutover enabled")
        print_status()

      opts[:disable] ->
        update_cfg(fn cfg -> Keyword.put(cfg, :enabled, false) end)
        Mix.shell().info("cutover disabled")
        print_status()

      is_binary(opts[:set_whitelist]) ->
        update_cfg(fn cfg ->
          Keyword.put(cfg, :tenant_whitelist, parse_tenant_csv(opts[:set_whitelist]))
        end)

        Mix.shell().info("cutover whitelist updated")
        print_status()

      opts[:rollback] ->
        update_cfg(fn cfg ->
          cfg
          |> Keyword.put(:enabled, false)
          |> Keyword.put(:tenant_whitelist, [])
        end)

        Mix.shell().info("rollback done: cutover disabled and whitelist cleared")
        print_status()

      opts[:drill] ->
        Mix.shell().info(
          "rollback drill: simulated at #{DateTime.utc_now() |> DateTime.to_iso8601()}"
        )
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

  defp parse_tenant_csv(csv) when is_binary(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp invalid_usage!(reason) do
    Mix.raise("""
    #{reason}
    usage: mix men.cutover --status|--enable|--disable|--set-whitelist <csv>|--rollback|--drill
    """)
  end
end
