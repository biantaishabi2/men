defmodule Men.Gateway.ActionExecutor do
  @moduledoc """
  Action 合约校验与同步执行分发。
  """

  alias Men.Gateway.Receipt
  alias Men.RuntimeBridge.Bridge

  @type action :: %{
          required(:action_id) => binary(),
          required(:name) => binary(),
          optional(:params) => map(),
          optional(:tool) => binary()
        }

  @type execute_context :: %{
          required(:run_id) => binary(),
          required(:session_key) => binary()
        }

  @spec execute_all([map()], execute_context(), keyword()) :: [Receipt.t()]
  def execute_all(actions, context, opts \\ []) when is_list(actions) do
    Enum.map(actions, &execute(&1, context, opts))
  end

  @spec execute(map(), execute_context(), keyword()) :: Receipt.t()
  def execute(action, context, opts \\ []) when is_map(action) and is_map(context) do
    with {:ok, normalized} <- normalize_action(action) do
      do_execute(normalized, context, opts)
    else
      {:error, reason} ->
        Receipt.new(%{
          run_id: context.run_id,
          action_id: action_id_fallback(action),
          status: :failed,
          code: "INVALID_ACTION",
          message: "invalid action contract",
          data: %{reason: inspect(reason)},
          retryable: false,
          ts: now_ms()
        })
    end
  end

  defp do_execute(action, context, opts) do
    dispatcher = Keyword.get(opts, :dispatcher, &default_dispatcher/3)

    case dispatcher.(action, context, opts) do
      {:ok, data} ->
        Receipt.new(%{
          run_id: context.run_id,
          action_id: action.action_id,
          status: :ok,
          code: "OK",
          message: "action executed",
          data: normalize_data(data),
          retryable: false,
          ts: now_ms()
        })

      {:error, error_info} ->
        build_failed_receipt(action, context, error_info)

      other ->
        build_failed_receipt(action, context, %{code: "DISPATCH_ERROR", message: inspect(other)})
    end
  end

  defp build_failed_receipt(action, context, error_info) do
    normalized_error_info = normalize_error_info(error_info)

    code =
      Map.get(normalized_error_info, :code) || Map.get(normalized_error_info, "code") ||
        "ACTION_FAILED"

    message =
      Map.get(normalized_error_info, :message) ||
        Map.get(normalized_error_info, "message") ||
        "action execution failed"

    retryable =
      Map.get(normalized_error_info, :retryable) ||
        Map.get(normalized_error_info, "retryable") ||
        false

    data =
      normalized_error_info
      |> normalize_data()
      |> Map.drop([:message, "message", :code, "code", :retryable, "retryable"])

    Receipt.new(%{
      run_id: context.run_id,
      action_id: action.action_id,
      status: :failed,
      code: to_string(code),
      message: to_string(message),
      data: data,
      retryable: retryable == true,
      ts: now_ms()
    })
  end

  defp normalize_error_info(%{} = error_info), do: error_info
  defp normalize_error_info(error_info), do: %{message: inspect(error_info), reason: error_info}

  defp default_dispatcher(action, context, _opts) do
    payload = %{
      run_id: context.run_id,
      session_key: context.session_key,
      action_id: action.action_id,
      name: action.name,
      params: action.params,
      tool: action.tool
    }

    Bridge.graph(action.name, payload)
  end

  defp normalize_action(action) do
    action_id = Map.get(action, :action_id) || Map.get(action, "action_id")
    name = Map.get(action, :name) || Map.get(action, "name")
    params = Map.get(action, :params) || Map.get(action, "params") || %{}
    tool = Map.get(action, :tool) || Map.get(action, "tool")

    cond do
      not (is_binary(action_id) and action_id != "") ->
        {:error, :invalid_action_id}

      not (is_binary(name) and name != "") ->
        {:error, :invalid_name}

      not is_map(params) ->
        {:error, :invalid_params}

      true ->
        {:ok, %{action_id: action_id, name: name, params: params, tool: normalize_tool(tool)}}
    end
  end

  defp normalize_tool(value) when is_binary(value) and value != "", do: value
  defp normalize_tool(_), do: nil

  defp normalize_data(%{} = data), do: data
  defp normalize_data(data), do: %{value: data}

  defp action_id_fallback(action) do
    Map.get(action, :action_id) || Map.get(action, "action_id") || "unknown_action"
  end

  defp now_ms, do: System.system_time(:millisecond)
end
