defmodule Men.Gateway.Routing do
  @moduledoc """
  Gateway 路由模块：只负责 session_key 计算与 route 决策。
  """

  alias Men.Gateway.Types
  alias Men.Routing.SessionKey

  @spec resolve(Types.inbound_event()) :: {:ok, Types.route_result()} | {:error, term()}
  def resolve(%{} = inbound_event) do
    with {:ok, channel} <- fetch_binary(inbound_event, :channel),
         {:ok, event_type} <- fetch_binary(inbound_event, :event_type),
         {:ok, session_key} <- resolve_session_key(inbound_event) do
      {:ok,
       %{
         session_key: session_key,
         channel: channel,
         event_type: event_type,
         target: %{channel: channel, metadata: Map.get(inbound_event, :metadata, %{})}
       }}
    end
  end

  def resolve(_), do: {:error, :invalid_event}

  @spec resolve_session_key(map()) :: {:ok, binary()} | {:error, term()}
  def resolve_session_key(%{session_key: session_key})
      when is_binary(session_key) and session_key != "",
      do: {:ok, session_key}

  def resolve_session_key(%{} = attrs) do
    SessionKey.build(%{
      channel: Map.get(attrs, :channel),
      user_id: Map.get(attrs, :user_id),
      group_id: Map.get(attrs, :group_id),
      thread_id: Map.get(attrs, :thread_id)
    })
  end

  def resolve_session_key(_), do: {:error, :invalid_event}

  defp fetch_binary(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end
end
