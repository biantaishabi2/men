defmodule Men.Gateway.Runtime.Protocol do
  @moduledoc """
  Runtime Node/Edge 统一协议入口。
  """

  alias Men.Gateway.Runtime.{Edge, Node}

  @type validation_error :: %{path: list(), code: atom(), message: binary()}

  @spec validate_node(map()) :: {:ok, map()} | {:error, [validation_error()]}
  def validate_node(input) when is_map(input) do
    if runtime_protocol_v2_enabled?() do
      Node.validate(input)
    else
      {:ok, input}
    end
  end

  def validate_node(_input), do: {:error, [error([], :invalid_type, "node 必须是 map")]}

  @spec validate_edge(map()) :: {:ok, map()} | {:error, [validation_error()]}
  def validate_edge(input) when is_map(input) do
    if runtime_protocol_v2_enabled?() do
      Edge.validate(input)
    else
      {:ok, input}
    end
  end

  def validate_edge(_input), do: {:error, [error([], :invalid_type, "edge 必须是 map")]}

  @spec encode(map()) :: {:ok, map()} | {:error, [validation_error()]}
  def encode(input) when is_map(input) do
    if runtime_protocol_v2_enabled?() do
      case detect_entity_type(input) do
        :node ->
          with {:ok, node} <- Node.validate(input) do
            {:ok,
             stringify_keys(node, [
               :id,
               :mode,
               :status,
               :version,
               :meta,
               :inserted_at,
               :updated_at,
               :requires_all,
               :options,
               :confidence
             ])}
          end

        :edge ->
          with {:ok, edge} <- Edge.validate(input) do
            {:ok, stringify_keys(edge, [:from, :to, :type, :condition, :weight, :meta])}
          end

        :unknown ->
          {:error, [error([], :invalid_value, "无法识别是 node 还是 edge")]}
      end
    else
      {:ok, input}
    end
  end

  def encode(_input), do: {:error, [error([], :invalid_type, "payload 必须是 map")]}

  @spec decode(map()) :: {:ok, map()} | {:error, [validation_error()]}
  def decode(input) when is_map(input) do
    mapped = map_legacy_fields(input)

    case detect_entity_type(mapped) do
      :node -> Node.validate(mapped)
      :edge -> Edge.validate(mapped)
      :unknown -> {:error, [error([], :invalid_value, "无法识别是 node 还是 edge")]}
    end
  end

  def decode(_input), do: {:error, [error([], :invalid_type, "payload 必须是 map")]}

  # legacy 字段兼容映射始终开启，保障回滚期间输入可被读取。
  defp map_legacy_fields(input) do
    input
    |> rename_key("node_type", "mode")
    |> rename_key(:node_type, :mode)
    |> rename_key("state", "status")
    |> rename_key(:state, :status)
    |> rename_key("created_at", "inserted_at")
    |> rename_key(:created_at, :inserted_at)
  end

  defp rename_key(map, from, to) do
    cond do
      Map.has_key?(map, to) ->
        map

      Map.has_key?(map, from) ->
        value = Map.get(map, from)

        map
        |> Map.delete(from)
        |> Map.put(to, value)

      true ->
        map
    end
  end

  defp stringify_keys(map, ordered_keys) do
    Enum.reduce(ordered_keys, %{}, fn key, acc ->
      if Map.has_key?(map, key) do
        Map.put(acc, Atom.to_string(key), Map.get(map, key))
      else
        acc
      end
    end)
  end

  defp detect_entity_type(payload) do
    cond do
      has_any_key?(payload, ["mode", :mode]) ->
        :node

      has_any_key?(payload, ["from", :from, "to", :to, "type", :type]) ->
        :edge

      has_any_key?(
        payload,
        [
          "status",
          :status,
          "version",
          :version,
          "requires_all",
          :requires_all,
          "options",
          :options,
          "confidence",
          :confidence,
          "inserted_at",
          :inserted_at,
          "updated_at",
          :updated_at
        ]
      ) ->
        :node

      has_any_key?(payload, ["id", :id]) ->
        :node

      true ->
        :unknown
    end
  end

  defp has_any_key?(payload, keys) do
    Enum.any?(keys, &Map.has_key?(payload, &1))
  end

  defp runtime_protocol_v2_enabled? do
    Application.get_env(:men, :runtime_protocol_v2, true) == true
  end

  defp error(path, code, message), do: %{path: path, code: code, message: message}
end
