defmodule Men.Channels.Egress.RouterAdapter do
  @moduledoc """
  按 session_key 前缀路由到具体渠道 egress adapter。
  """

  @behaviour Men.Channels.Egress.Adapter

  alias Men.Channels.Egress.Messages
  alias Men.Channels.Egress.Messages.EventMessage
  alias Men.Channels.Egress.{DingtalkRobotAdapter, FeishuAdapter}

  @impl true
  def send(target, message) do
    effective_target = resolve_target(target, message)

    case resolve_adapter(effective_target) do
      {:ok, adapter} -> adapter.send(effective_target, message)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_target(target, _message) when is_binary(target) and target != "", do: target

  defp resolve_target(target, %EventMessage{metadata: metadata}) when is_map(target) do
    ensure_map_session_key(target, metadata)
  end

  defp resolve_target(target, %{metadata: metadata}) when is_map(target) do
    ensure_map_session_key(target, metadata)
  end

  defp resolve_target(target, %{metadata: metadata}), do: target || Messages.metadata_value(metadata, :session_key, nil)

  defp resolve_target(target, _message), do: target

  # map target 需保持透传，仅在缺少 session_key 时补齐路由键。
  defp ensure_map_session_key(target, metadata) do
    if map_target_session_key(target) do
      target
    else
      case Messages.metadata_value(metadata, :session_key, nil) do
        session_key when is_binary(session_key) and session_key != "" ->
          Map.put(target, :session_key, session_key)

        _ ->
          target
      end
    end
  end

  defp resolve_adapter(%{} = target) do
    session_key = map_target_session_key(target)

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

  defp map_target_session_key(target) do
    Map.get(target, :session_key) ||
      Map.get(target, "session_key") ||
      Map.get(target, :target) ||
      Map.get(target, "target")
  end
end
