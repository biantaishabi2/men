defmodule Men.Channels.Egress.RouterAdapter do
  @moduledoc """
  按 session_key 前缀路由到具体渠道 egress adapter。
  """

  @behaviour Men.Channels.Egress.Adapter

  alias Men.Channels.Egress.{DingtalkRobotAdapter, FeishuAdapter}

  @impl true
  def send(target, message) do
    case resolve_adapter(target) do
      {:ok, adapter} -> adapter.send(target, message)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_adapter(%{} = target) do
    session_key =
      Map.get(target, :session_key) ||
        Map.get(target, "session_key") ||
        Map.get(target, :target) ||
        Map.get(target, "target")

    resolve_adapter(session_key)
  end

  defp resolve_adapter(target) when is_binary(target) do
    cond do
      String.starts_with?(target, "feishu:") -> {:ok, FeishuAdapter}
      String.starts_with?(target, "dingtalk:") -> {:ok, DingtalkRobotAdapter}
      true -> {:error, :unsupported_channel}
    end
  end

  defp resolve_adapter(_), do: {:error, :unsupported_channel}
end
