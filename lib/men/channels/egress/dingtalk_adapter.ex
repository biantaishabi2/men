defmodule Men.Channels.Egress.DingtalkAdapter do
  @moduledoc """
  钉钉出站适配：将 dispatch 结果映射为 webhook 回写 body。
  """

  @timeout_codes MapSet.new(["CLI_TIMEOUT", "BRIDGE_TIMEOUT", "TIMEOUT"])

  @spec to_webhook_response({:ok, map()} | {:error, map()}) :: {non_neg_integer(), map()}
  def to_webhook_response({:ok, result}) when is_map(result) do
    {200,
     %{
       status: "final",
       code: "OK",
       message: Map.get(result, :payload, %{}) |> Map.get(:text, "ok"),
       request_id: Map.get(result, :request_id),
       run_id: Map.get(result, :run_id)
     }}
  end

  def to_webhook_response({:error, error}) when is_map(error) do
    status = if timeout_error?(error), do: "timeout", else: "error"
    code = Map.get(error, :code, "DISPATCH_ERROR")

    {200,
     %{
       status: status,
       code: code,
       message: Map.get(error, :reason, "dispatch failed"),
       request_id: Map.get(error, :request_id),
       run_id: Map.get(error, :run_id),
       details: Map.get(error, :metadata, %{})
     }}
  end

  def to_webhook_response({:error, error}) do
    {200,
     %{
       status: "error",
       code: "INTERNAL_ERROR",
       message: inspect(error)
     }}
  end

  defp timeout_error?(error) do
    code = Map.get(error, :code)
    metadata = Map.get(error, :metadata, %{})

    MapSet.member?(@timeout_codes, code) or timeout_type?(Map.get(metadata, :type))
  end

  defp timeout_type?(:timeout), do: true
  defp timeout_type?("timeout"), do: true
  defp timeout_type?(_), do: false
end
