defmodule Mix.Tasks.Men.OpsPolicy.Get do
  @moduledoc """
  读取指定策略并输出来源/版本/缓存命中信息。
  """

  use Mix.Task

  alias Men.Ops.Policy

  @shortdoc "读取 Ops Policy 诊断信息"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case parse_args(args) do
      {:ok, identity} ->
        case Policy.get(identity) do
          {:ok, result} ->
            Mix.shell().info("value=#{Jason.encode!(result.value)}")
            Mix.shell().info("version=#{result.version}")
            Mix.shell().info("source=#{result.source}")
            Mix.shell().info("cache_hit=#{result.cache_hit}")
            Mix.shell().info("fallback_reason=#{inspect(result.fallback_reason)}")

          {:error, reason} ->
            Mix.raise("ops policy get failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("invalid arguments: #{inspect(reason)}")
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args,
           strict: [tenant: :string, env: :string, scope: :string, key: :string]
         ) do
      {opts, _, _} ->
        identity = %{
          tenant: opts[:tenant],
          env: opts[:env],
          scope: opts[:scope],
          policy_key: opts[:key]
        }

        if Enum.all?(
             [identity.tenant, identity.env, identity.scope, identity.policy_key],
             &(is_binary(&1) and &1 != "")
           ) do
          {:ok, identity}
        else
          {:error, :missing_required_args}
        end
    end
  end
end
