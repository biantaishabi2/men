defmodule Men.RuntimeBridge.Bridge do
  @moduledoc """
  Runtime Bridge 契约。

  兼容两条调用路径：
  - `call/2`: 结构体请求/响应契约（L0 基础契约）
  - `start_turn/2`: GongCLI 统一语义契约（运行时桥接）
  """

  alias Men.RuntimeBridge.{ErrorResponse, Request, Response, TaskctlAdapter}
  alias Men.Gateway.Runtime.GraphContract

  @type error_type :: :failed | :timeout | :overloaded

  @type error_payload :: %{
          type: error_type(),
          code: binary(),
          message: binary(),
          run_id: binary(),
          request_id: binary(),
          session_key: binary(),
          details: map() | nil
        }

  @type success_payload :: %{
          text: binary(),
          meta: map()
        }

  @typedoc """
  start_turn/2 第二个参数使用的追踪上下文。
  """
  @type turn_context :: %{
          optional(:request_id) => binary(),
          optional(:session_key) => binary(),
          optional(:run_id) => binary()
        }

  @callback call(Request.t(), opts :: keyword()) ::
              {:ok, Response.t()} | {:error, ErrorResponse.t()}

  @callback start_turn(prompt :: binary(), context :: turn_context()) ::
              {:ok, success_payload()} | {:error, error_payload()}

  @optional_callbacks call: 2, start_turn: 2

  @spec graph(GraphContract.action() | String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, ErrorResponse.t()}
  def graph(action, payload, opts \\ []) do
    graph_adapter = opts[:graph_adapter] || config(:graph_adapter, TaskctlAdapter)
    graph_adapter.run(action, payload, opts)
  end

  defp config(key, default) do
    :men
    |> Application.get_env(:runtime_bridge, [])
    |> Keyword.get(key, default)
  end
end
