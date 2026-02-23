defmodule Men.Ops.Policy.Events do
  @moduledoc """
  Ops Policy 事件发布与订阅。
  """

  @topic "ops_policy_changed"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Men.PubSub, @topic)
  end

  @spec publish_changed(non_neg_integer()) :: :ok
  def publish_changed(version) when is_integer(version) and version >= 0 do
    _ = Phoenix.PubSub.broadcast(Men.PubSub, @topic, {:policy_changed, version})
    :ok
  rescue
    _ -> :ok
  end

  @spec topic() :: String.t()
  def topic, do: @topic
end
