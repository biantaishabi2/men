defmodule Men.Gateway.Runtime.GraphContract do
  @moduledoc """
  men 侧三图调用契约：

  - 统一 action 命名
  - 统一输入校验
  - 统一输出归一化
  """

  @typedoc "双图动作类型（research + execute）"
  @type action :: :research_reduce | :execute_compile

  @typedoc "标准化后的调用请求"
  @type request :: %{
          action: action(),
          input: map()
        }

  @typedoc "标准化后的调用结果"
  @type normalized_result :: %{
          action: action(),
          result: String.t(),
          data: map(),
          diagnostics: map()
        }

  @spec build_request(action() | String.t(), term()) :: {:ok, request()} | {:error, String.t()}
  def build_request(action, payload) do
    with {:ok, normalized_action} <- normalize_action(action),
         :ok <- validate_payload(payload) do
      {:ok, %{action: normalized_action, input: payload}}
    end
  end

  @spec normalize_response(action(), term()) :: {:ok, normalized_result()} | {:error, String.t()}
  def normalize_response(action, response) when is_map(response) do
    result = Map.get(response, "result") || Map.get(response, :result)

    cond do
      not is_binary(result) ->
        {:error, "missing result field"}

      true ->
        diagnostics =
          Map.get(response, "diagnostics") ||
            Map.get(response, :diagnostics) ||
            %{}

        data =
          response
          |> Map.drop(["result", :result, "diagnostics", :diagnostics])
          |> stringify_map_keys()

        {:ok,
         %{
           action: action,
           result: result,
           data: data,
           diagnostics: stringify_map_keys(diagnostics)
         }}
    end
  end

  def normalize_response(_action, _response), do: {:error, "response must be a map"}

  @spec normalize_action(action() | String.t()) :: {:ok, action()} | {:error, String.t()}
  def normalize_action(action) when action in [:research_reduce, :execute_compile],
    do: {:ok, action}

  def normalize_action("research_reduce"), do: {:ok, :research_reduce}
  def normalize_action("execute_compile"), do: {:ok, :execute_compile}
  def normalize_action(_), do: {:error, "unsupported action"}

  @spec action_tokens(action()) :: [String.t()]
  def action_tokens(:research_reduce), do: ["research", "reduce"]
  def action_tokens(:execute_compile), do: ["execute", "compile"]

  defp validate_payload(payload) when is_map(payload), do: :ok
  defp validate_payload(_), do: {:error, "payload must be a map"}

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
      value = if is_map(v), do: stringify_map_keys(v), else: v
      {key, value}
    end)
  end
end
