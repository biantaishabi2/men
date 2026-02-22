defmodule Men.RuntimeBridge.TaskctlAdapter do
  @moduledoc """
  men -> Cli taskctl 双图命令桥接层（research + execute）。

  默认通过 `System.cmd/3` 调用本地 `taskctl`，并统一输出契约。
  """

  alias Men.Gateway.Runtime.GraphContract
  alias Men.RuntimeBridge.ErrorResponse

  @type runner ::
          (cmd :: String.t(), args :: [String.t()], input :: String.t() ->
             {output :: String.t(), exit_status :: non_neg_integer()})

  @spec run(GraphContract.action() | String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, ErrorResponse.t()}
  def run(action, payload, opts \\ []) do
    with {:ok, request} <- GraphContract.build_request(action, payload),
         {:ok, json_input} <- Jason.encode(request.input),
         {:ok, raw_response} <- invoke_taskctl(request.action, json_input, opts),
         {:ok, decoded} <- decode_json(raw_response),
         {:ok, normalized} <- GraphContract.normalize_response(request.action, decoded) do
      {:ok, normalized}
    else
      {:error, %ErrorResponse{} = err} ->
        {:error, err}

      {:error, reason} when is_binary(reason) ->
        {:error, contract_error(payload, reason)}
    end
  end

  defp invoke_taskctl(action, json_input, opts) do
    cmd = opts[:cmd] || config(:cmd, "taskctl")
    args = build_args(action, opts)
    runner = opts[:runner] || (&default_runner/3)
    {output, status} = runner.(cmd, args, json_input)

    if status == 0 do
      {:ok, output}
    else
      {:error, shell_error(status, output)}
    end
  end

  defp build_args(action, opts) do
    configured = opts[:taskctl_args] || config(:taskctl_args, [])

    case configured do
      [] -> GraphContract.action_tokens(action)
      list when is_list(list) -> list
    end
  end

  defp decode_json(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, err} -> {:error, "invalid json output: #{Exception.message(err)}"}
    end
  end

  # 这里使用临时 JSON 文件传入 --input，兼容 System.cmd 无 stdin 输入选项的环境。
  defp default_runner(cmd, args, input) do
    tmp = temp_input_path()
    File.write!(tmp, input)

    final_args =
      if Enum.member?(args, "--input") do
        args
      else
        args ++ ["--input", tmp]
      end

    try do
      System.cmd(cmd, final_args, stderr_to_stdout: true)
    after
      File.rm(tmp)
    end
  end

  defp shell_error(status, output) do
    %ErrorResponse{
      session_key: "taskctl",
      reason: "taskctl command failed",
      code: "taskctl_exit_non_zero",
      metadata: %{
        exit_status: status,
        output: output
      }
    }
  end

  defp contract_error(payload, reason) do
    %ErrorResponse{
      session_key: Map.get(payload, :session_key, Map.get(payload, "session_key", "taskctl")),
      reason: reason,
      code: "graph_contract_error",
      metadata: %{source: :graph_contract}
    }
  end

  defp config(key, default) do
    :men
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp temp_input_path do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(System.tmp_dir!(), "men-taskctl-#{suffix}.json")
  end
end
