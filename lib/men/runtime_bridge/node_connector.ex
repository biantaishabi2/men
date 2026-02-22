defmodule Men.RuntimeBridge.NodeConnector do
  @moduledoc """
  Gong 分布式节点连接管理。
  """

  @default_node_start_type :longnames

  defmodule RPCClient do
    @moduledoc false
    @callback ping(node()) :: :pong | :pang
  end

  @behaviour RPCClient

  @impl true
  def ping(node), do: Node.ping(node)

  @spec ensure_connected(keyword(), module()) :: {:ok, node()} | {:error, map()}
  def ensure_connected(cfg, rpc_client \\ __MODULE__) do
    with {:ok, gong_node} <- fetch_gong_node(cfg),
         :ok <- ensure_local_node_alive(cfg),
         :ok <- maybe_apply_cookie(cfg),
         :ok <- ensure_node_connected(gong_node, rpc_client) do
      {:ok, gong_node}
    end
  end

  defp fetch_gong_node(cfg) do
    case normalize_node_name(Keyword.get(cfg, :gong_node)) do
      {:ok, node} -> {:ok, node}
      :error -> {:error, error_payload("NODE_CONFIG_ERROR", "gong rpc node is not configured")}
    end
  end

  defp maybe_apply_cookie(cfg) do
    case Keyword.get(cfg, :cookie) do
      nil ->
        :ok

      cookie when is_binary(cookie) and cookie != "" ->
        Node.set_cookie(String.to_atom(cookie))
        :ok

      cookie when is_atom(cookie) ->
        Node.set_cookie(cookie)
        :ok

      _ ->
        {:error, error_payload("COOKIE_CONFIG_ERROR", "invalid gong rpc cookie")}
    end
  end

  defp ensure_local_node_alive(cfg) do
    if Node.alive?() do
      :ok
    else
      with {:ok, local_node} <- fetch_local_node(cfg),
           {:ok, node_type} <- fetch_node_type(cfg),
           {:ok, _pid} <- start_local_node(local_node, node_type) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_local_node(cfg) do
    case normalize_node_name(Keyword.get(cfg, :local_node)) do
      {:ok, node} ->
        {:ok, node}

      :error ->
        {:error,
         error_payload(
           "NODE_NOT_DISTRIBUTED",
           "local node is not alive and local_node is not configured"
         )}
    end
  end

  defp fetch_node_type(cfg) do
    case Keyword.get(cfg, :node_start_type, @default_node_start_type) do
      :shortnames -> {:ok, :shortnames}
      :longnames -> {:ok, :longnames}
      _ -> {:error, error_payload("NODE_CONFIG_ERROR", "invalid node_start_type")}
    end
  end

  defp start_local_node(local_node, node_type) do
    case Node.start(local_node, node_type) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        {:ok, self()}

      {:error, reason} ->
        {:error,
         error_payload("NODE_START_FAILED", "failed to start local distributed node", %{
           reason: inspect(reason),
           local_node: Atom.to_string(local_node),
           node_start_type: node_type
         })}
    end
  end

  defp ensure_node_connected(gong_node, rpc_client) do
    connected? = Node.connect(gong_node)

    cond do
      connected? and rpc_client.ping(gong_node) == :pong ->
        :ok

      true ->
        {:error,
         error_payload("NODE_DISCONNECTED", "failed to connect gong node", %{
           gong_node: Atom.to_string(gong_node),
           ping: inspect(rpc_client.ping(gong_node))
         })}
    end
  end

  defp normalize_node_name(value) when is_atom(value), do: {:ok, value}

  defp normalize_node_name(value) when is_binary(value) do
    if value == "" do
      :error
    else
      {:ok, String.to_atom(value)}
    end
  end

  defp normalize_node_name(_), do: :error

  defp error_payload(code, message, details \\ %{}) do
    %{
      type: :failed,
      code: code,
      message: message,
      details: details
    }
  end
end
