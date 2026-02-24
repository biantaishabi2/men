defmodule Mix.Tasks.Men.OpsPolicy.Put do
  @moduledoc """
  写入（upsert）一条 Ops Policy。
  """

  use Mix.Task

  alias Men.Ops.Policy

  @shortdoc "写入 Ops Policy"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    with {:ok, identity, opts} <- parse_args(args),
         {:ok, value} <- load_value(opts),
         :ok <- validate_value(value),
         {:ok, result} <- Policy.put(identity, value, updated_by: opts.updated_by) do
      Mix.shell().info("status=ok")
      Mix.shell().info("version=#{result.version}")
      Mix.shell().info("source=#{result.source}")
      Mix.shell().info("value=#{Jason.encode!(result.value)}")
    else
      {:error, reason} ->
        Mix.raise("ops policy put failed: #{inspect(reason)}")
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
          value_json: :string,
          value_file: :string,
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
      {:ok, identity,
       %{
         value_json: opts[:value_json],
         value_file: opts[:value_file],
         updated_by: opts[:updated_by] || "ops_cli"
       }}
    else
      {:error, :missing_required_args}
    end
  end

  defp load_value(%{value_file: path}) when is_binary(path) and path != "" do
    with {:ok, content} <- File.read(path),
         {:ok, value} <- Jason.decode(content) do
      {:ok, value}
    else
      {:error, reason} -> {:error, {:invalid_value_file, reason}}
    end
  end

  defp load_value(%{value_json: json}) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_value_json, reason}}
    end
  end

  defp load_value(_), do: {:error, :missing_value}

  defp validate_value(%{
         "acl" => acl,
         "wake" => wake,
         "dedup_ttl_ms" => dedup_ttl_ms
       })
       when is_map(acl) and is_map(wake) and is_integer(dedup_ttl_ms) and dedup_ttl_ms > 0 do
    :ok
  end

  defp validate_value(_), do: {:error, :invalid_value_shape}
end
