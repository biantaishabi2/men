defmodule Men.Gateway.ReplAcl do
  @moduledoc """
  REPL 共享状态 ACL：默认拒绝，按角色矩阵判定读写权限。
  """

  require Logger

  @type actor :: %{
          required(:role) => :main | :child | :tool | :system,
          required(:session_key) => String.t(),
          optional(:agent_id) => String.t(),
          optional(:tool_id) => String.t()
        }

  @spec authorize_read(map(), String.t(), map(), map()) :: :ok | {:error, :acl_denied}
  def authorize_read(actor, key, policy, context \\ %{}) do
    authorize(:read, actor, key, policy, context)
  end

  @spec authorize_write(map(), String.t(), map(), map()) :: :ok | {:error, :acl_denied}
  def authorize_write(actor, key, policy, context \\ %{}) do
    authorize(:write, actor, key, policy, context)
  end

  @spec normalize_actor(map()) :: {:ok, actor()} | {:error, :acl_denied}
  def normalize_actor(%{} = actor) do
    role =
      case Map.get(actor, :role) || Map.get(actor, "role") do
        role when role in [:main, :child, :tool, :system] -> role
        "main" -> :main
        "child" -> :child
        "tool" -> :tool
        "system" -> :system
        _ -> nil
      end

    session_key = Map.get(actor, :session_key) || Map.get(actor, "session_key")
    agent_id = Map.get(actor, :agent_id) || Map.get(actor, "agent_id")
    tool_id = Map.get(actor, :tool_id) || Map.get(actor, "tool_id")

    cond do
      role == nil ->
        {:error, :acl_denied}

      not (is_binary(session_key) and session_key != "") ->
        {:error, :acl_denied}

      role in [:child, :tool] and not (is_binary(agent_id) and agent_id != "") ->
        {:error, :acl_denied}

      role == :tool and not (is_binary(tool_id) and tool_id != "") ->
        {:error, :acl_denied}

      true ->
        {:ok,
         %{
           role: role,
           session_key: session_key,
           agent_id: normalize_optional(agent_id),
           tool_id: normalize_optional(tool_id)
         }}
    end
  end

  def normalize_actor(_), do: {:error, :acl_denied}

  defp authorize(action, actor, key, policy, context) when action in [:read, :write] do
    with {:ok, normalized_actor} <- normalize_actor(actor),
         true <- is_binary(key) and key != "",
         {:ok, prefixes} <- policy_prefixes(policy, normalized_actor.role, action),
         true <- allowed?(key, prefixes, normalized_actor) do
      :ok
    else
      _ ->
        emit_acl_denied(key, action, actor, context, policy)
        {:error, :acl_denied}
    end
  end

  defp policy_prefixes(policy, role, action) do
    acl_map =
      case policy do
        %{acl: %{} = acl} -> acl
        %{"acl" => %{} = acl} -> acl
        _ -> %{}
      end

    role_key = Atom.to_string(role)

    prefixes =
      acl_map
      |> Map.get(role_key, %{})
      |> then(fn role_acl -> Map.get(role_acl, Atom.to_string(action), []) end)
      |> List.wrap()

    if prefixes == [], do: {:error, :acl_denied}, else: {:ok, prefixes}
  end

  defp allowed?(key, prefixes, actor) do
    Enum.any?(prefixes, fn prefix ->
      expanded =
        prefix
        |> to_string()
        |> String.replace("$agent_id", actor.agent_id || "")
        |> String.replace("$tool_id", actor.tool_id || "")

      String.starts_with?(key, expanded)
    end)
  end

  defp emit_acl_denied(key, action, actor, context, policy) do
    payload =
      %{
        key: key,
        action: action,
        role: Map.get(actor, :role) || Map.get(actor, "role"),
        session_key: Map.get(actor, :session_key) || Map.get(actor, "session_key"),
        event_id: Map.get(context, :event_id),
        type: Map.get(context, :type),
        source: Map.get(context, :source),
        policy_version: policy_version(policy)
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    Logger.warning("acl_denied #{Jason.encode!(payload)}")
  rescue
    _ -> :ok
  end

  defp policy_version(policy) do
    Map.get(policy, :policy_version) || Map.get(policy, "policy_version") || "unknown"
  end

  defp normalize_optional(value) when is_binary(value) and value != "", do: value
  defp normalize_optional(_), do: nil
end
