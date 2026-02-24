defmodule Mix.Tasks.Men.OpsPolicy.Delete do
  @moduledoc """
  删除（软删除）一条 Ops Policy。
  """

  use Mix.Task

  alias Men.Ops.Policy

  @shortdoc "删除 Ops Policy"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    with {:ok, identity, updated_by} <- parse_args(args),
         {:ok, result} <- Policy.delete(identity, updated_by: updated_by) do
      Mix.shell().info("status=ok")
      Mix.shell().info("version=#{result.version}")
      Mix.shell().info("source=#{result.source}")
    else
      {:error, reason} ->
        Mix.raise("ops policy delete failed: #{inspect(reason)}")
    end
  end

  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          tenant: :string,
          env: :string,
          scope: :string,
          key: :string,
          updated_by: :string
        ]
      )

    identity = %{
      tenant: opts[:tenant],
      env: opts[:env],
      scope: opts[:scope],
      policy_key: opts[:key]
    }

    if Enum.all?(Map.values(identity), &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, identity, opts[:updated_by] || "ops_cli"}
    else
      {:error, :missing_required_args}
    end
  end
end
