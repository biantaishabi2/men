defmodule Men.Gateway.Runtime.Edge do
  @moduledoc """
  Runtime Edge v1 协议校验。
  """

  @required_fields [:from, :to, :type]
  @optional_fields [:condition, :weight, :meta]
  @allowed_fields @required_fields ++ @optional_fields

  @type validation_error :: %{path: list(), code: atom(), message: binary()}

  @spec validate(map()) :: {:ok, map()} | {:error, [validation_error()]}
  def validate(input) when is_map(input) do
    normalized = normalize_known_fields(input)

    with :ok <- reject_unknown_fields(input, normalized),
         :ok <- validate_required_binary(normalized, :from),
         :ok <- validate_required_binary(normalized, :to),
         :ok <- validate_required_binary(normalized, :type),
         :ok <- validate_optional_condition(normalized),
         :ok <- validate_optional_weight(normalized),
         :ok <- validate_meta(normalized) do
      {:ok, normalize_nil_meta(normalized)}
    else
      {:error, error} -> {:error, [error]}
    end
  end

  def validate(_input), do: {:error, [error([], :invalid_type, "edge 必须是 map")]}

  defp normalize_known_fields(input) do
    Enum.reduce(input, %{}, fn {key, value}, acc ->
      case normalize_key(key) do
        nil -> acc
        normalized_key -> Map.put(acc, normalized_key, value)
      end
    end)
  end

  defp normalize_key(key) when is_atom(key) and key in @allowed_fields, do: key

  defp normalize_key(key) when is_binary(key) do
    case key do
      "from" -> :from
      "to" -> :to
      "type" -> :type
      "condition" -> :condition
      "weight" -> :weight
      "meta" -> :meta
      _ -> nil
    end
  end

  defp normalize_key(_), do: nil

  defp reject_unknown_fields(original, _normalized) do
    case Enum.find_value(original, fn {key, _value} ->
           if is_nil(normalize_key(key)), do: key, else: nil
         end) do
      nil -> :ok
      unknown_key -> {:error, error([unknown_key], :unknown_field, "字段未定义")}
    end
  end

  defp validate_required_binary(edge, key) do
    case Map.get(edge, key) do
      value when is_binary(value) and value != "" -> :ok
      nil -> {:error, error([key], :required, "#{key} 为必填字段")}
      _ -> {:error, error([key], :invalid_type, "#{key} 必须为非空字符串")}
    end
  end

  defp validate_optional_condition(edge) do
    case Map.get(edge, :condition) do
      nil -> :ok
      value when is_binary(value) -> :ok
      _ -> {:error, error([:condition], :invalid_type, "condition 必须为字符串")}
    end
  end

  defp validate_optional_weight(edge) do
    case Map.get(edge, :weight) do
      nil -> :ok
      value when is_integer(value) -> :ok
      value when is_float(value) -> :ok
      _ -> {:error, error([:weight], :invalid_type, "weight 必须为数字")}
    end
  end

  defp validate_meta(edge) do
    case Map.get(edge, :meta) do
      nil -> :ok
      value when is_map(value) -> :ok
      _ -> {:error, error([:meta], :invalid_type, "meta 必须为 map")}
    end
  end

  defp normalize_nil_meta(edge) do
    if Map.get(edge, :meta) == nil do
      Map.put(edge, :meta, %{})
    else
      edge
    end
  end

  defp error(path, code, message), do: %{path: path, code: code, message: message}
end
