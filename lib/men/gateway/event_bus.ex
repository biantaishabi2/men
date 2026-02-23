defmodule Men.Gateway.EventBus do
  @moduledoc """
  网关事件总线薄封装，仅承载轻量事件信号。
  """

  @default_topic "gateway_events"

  @spec publish(String.t(), map()) :: :ok
  def publish(topic \\ @default_topic, payload) when is_binary(topic) and is_map(payload) do
    Phoenix.PubSub.broadcast(Men.PubSub, topic, {:gateway_event, payload})
  rescue
    _ -> :ok
  end

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic \\ @default_topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(Men.PubSub, topic)
  end
end
