defmodule Men.Gateway.Runtime.Node do
  @moduledoc """
  Runtime Node v1 协议校验。
  """

  @common_fields [:id, :mode, :status, :version, :meta, :inserted_at, :updated_at]
  @plan_only_fields [:requires_all, :options, :confidence]
  @allowed_fields @common_fields ++ @plan_only_fields
  @allowed_modes ["research", "plan", "execute"]

  @type validation_error :: %{path: list(), code: atom(), message: binary()}

  @spec validate(map()) :: {:ok, map()} | {:error, [validation_error()]}
  def validate(input) when is_map(input) do
    normalized = normalize_known_fields(input)

    with :ok <- reject_unknown_fields(input, normalized),
         {:ok, mode} <- validate_mode(normalized),
         {:ok, node} <- normalize_for_mode(normalized, mode),
         :ok <- validate_required_and_types(node, mode) do
      {:ok, node}
    else
      {:error, error} -> {:error, [error]}
    end
  end

  def validate(_input), do: {:error, [error([], :invalid_type, "node 必须是 map")]}

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
      "id" -> :id
      "mode" -> :mode
      "status" -> :status
      "version" -> :version
      "meta" -> :meta
      "inserted_at" -> :inserted_at
      "updated_at" -> :updated_at
      "requires_all" -> :requires_all
      "options" -> :options
      "confidence" -> :confidence
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

  defp validate_mode(node) do
    case Map.fetch(node, :mode) do
      {:ok, mode} when is_binary(mode) and mode in @allowed_modes -> {:ok, mode}
      {:ok, nil} -> {:error, error([:mode], :invalid_value, "mode 不能为空")}
      {:ok, _} -> {:error, error([:mode], :invalid_value, "mode 必须为 research/plan/execute")}
      :error -> {:error, error([:mode], :required, "mode 为必填字段")}
    end
  end

  defp normalize_for_mode(node, mode) do
    with :ok <- validate_mode_specific_fields(node, mode),
         {:ok, node} <- normalize_status(node, mode) do
      {:ok,
       node
       |> Map.put_new(:version, 1)
       |> normalize_nullable_map(:meta, %{})
       |> normalize_plan_defaults(mode)}
    end
  end

  # 仅 plan 模式允许并补齐专有字段默认值，避免字段泄漏到其他模式。
  defp normalize_plan_defaults(node, "plan") do
    node
    |> normalize_nullable_list(:requires_all, [])
    |> normalize_nullable_map(:options, %{})
  end

  defp normalize_plan_defaults(node, _mode), do: node

  defp validate_mode_specific_fields(_node, "plan"), do: :ok

  defp validate_mode_specific_fields(node, _mode) do
    case Enum.find([:requires_all, :options, :confidence], &Map.has_key?(node, &1)) do
      nil -> :ok
      field -> {:error, error([field], :unknown_field, "当前 mode 不允许该字段")}
    end
  end

  defp normalize_status(node, mode) do
    has_status_key? = Map.has_key?(node, :status)

    cond do
      has_status_key? and Map.get(node, :status) == nil ->
        {:error, error([:status], :invalid_value, "status 不能为 nil")}

      has_status_key? ->
        {:ok, node}

      mode == "research" ->
        {:ok, Map.put(node, :status, "pending")}

      mode == "plan" ->
        {:ok, Map.put(node, :status, "draft")}

      mode == "execute" ->
        {:error, error([:status], :required, "execute 模式必须提供 status")}
    end
  end

  defp validate_required_and_types(node, mode) do
    with :ok <- validate_required_binary(node, :id),
         :ok <- validate_required_binary(node, :status),
         :ok <- validate_version(node),
         :ok <- validate_meta(node),
         :ok <- validate_optional_time(node, :inserted_at),
         :ok <- validate_optional_time(node, :updated_at),
         :ok <- validate_plan_fields(node, mode) do
      :ok
    end
  end

  defp validate_required_binary(node, key) do
    case Map.get(node, key) do
      value when is_binary(value) and value != "" -> :ok
      nil -> {:error, error([key], :required, "#{key} 为必填字段")}
      _ -> {:error, error([key], :invalid_type, "#{key} 必须为非空字符串")}
    end
  end

  defp validate_version(node) do
    case Map.get(node, :version) do
      value when is_integer(value) and value > 0 -> :ok
      nil -> {:error, error([:version], :required, "version 为必填字段")}
      _ -> {:error, error([:version], :invalid_type, "version 必须为正整数")}
    end
  end

  defp validate_meta(node) do
    case Map.get(node, :meta) do
      value when is_map(value) -> :ok
      _ -> {:error, error([:meta], :invalid_type, "meta 必须为 map")}
    end
  end

  defp validate_optional_time(node, key) do
    case Map.get(node, key) do
      nil -> :ok
      value when is_binary(value) and value != "" -> :ok
      _ -> {:error, error([key], :invalid_type, "#{key} 必须为字符串时间")}
    end
  end

  defp validate_plan_fields(node, "plan") do
    with :ok <- validate_requires_all(node),
         :ok <- validate_options(node),
         :ok <- validate_confidence(node) do
      :ok
    end
  end

  defp validate_plan_fields(_node, _mode), do: :ok

  defp validate_requires_all(node) do
    case Map.get(node, :requires_all, []) do
      value when is_list(value) ->
        if Enum.all?(value, &is_binary/1) do
          :ok
        else
          {:error, error([:requires_all], :invalid_type, "requires_all 必须为字符串列表")}
        end

      _ ->
        {:error, error([:requires_all], :invalid_type, "requires_all 必须为字符串列表")}
    end
  end

  defp validate_options(node) do
    case Map.get(node, :options, %{}) do
      value when is_map(value) -> :ok
      _ -> {:error, error([:options], :invalid_type, "options 必须为 map")}
    end
  end

  defp validate_confidence(node) do
    case Map.get(node, :confidence) do
      nil -> :ok
      value when is_integer(value) and value >= 0 and value <= 1 -> :ok
      value when is_float(value) and value >= 0.0 and value <= 1.0 -> :ok
      _ -> {:error, error([:confidence], :invalid_value, "confidence 必须在 0.0..1.0")}
    end
  end

  defp normalize_nullable_map(node, key, fallback) do
    if Map.has_key?(node, key) and Map.get(node, key) == nil do
      Map.put(node, key, fallback)
    else
      Map.put_new(node, key, fallback)
    end
  end

  defp normalize_nullable_list(node, key, fallback) do
    if Map.has_key?(node, key) and Map.get(node, key) == nil do
      Map.put(node, key, fallback)
    else
      Map.put_new(node, key, fallback)
    end
  end

  defp error(path, code, message), do: %{path: path, code: code, message: message}
end
