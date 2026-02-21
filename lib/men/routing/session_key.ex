defmodule Men.Routing.SessionKey do
  @moduledoc """
  生成会话键（session_key）的统一规则。

  规则：
  - 基础段：`{channel}:{user_id}`
  - 可选段：有 `group_id` 时追加 `:g:{group_id}`
  - 可选段：有 `thread_id` 时追加 `:t:{thread_id}`

  段值字符集限制为 `[a-zA-Z0-9_-]`。
  """

  @segment_regex ~r/^[a-zA-Z0-9_-]+$/

  @spec build(map()) :: {:ok, String.t()} | {:error, :invalid_segment | :missing_required_field}
  def build(%{channel: channel, user_id: user_id} = attrs) do
    with :ok <- validate_required_segment(channel),
         :ok <- validate_required_segment(user_id),
         :ok <- validate_optional_segment(Map.get(attrs, :group_id)),
         :ok <- validate_optional_segment(Map.get(attrs, :thread_id)) do
      key =
        [to_string(channel), to_string(user_id)]
        |> append_optional("g", Map.get(attrs, :group_id))
        |> append_optional("t", Map.get(attrs, :thread_id))
        |> Enum.join(":")

      {:ok, key}
    end
  end

  def build(_attrs), do: {:error, :missing_required_field}

  defp append_optional(parts, _tag, nil), do: parts
  defp append_optional(parts, _tag, ""), do: parts

  defp append_optional(parts, tag, value) do
    parts ++ [tag, to_string(value)]
  end

  defp validate_required_segment(nil), do: {:error, :missing_required_field}
  defp validate_required_segment(""), do: {:error, :missing_required_field}
  defp validate_required_segment(value), do: validate_segment(value)

  defp validate_optional_segment(nil), do: :ok
  defp validate_optional_segment(""), do: :ok
  defp validate_optional_segment(value), do: validate_segment(value)

  defp validate_segment(value) when is_binary(value) do
    if String.match?(value, @segment_regex), do: :ok, else: {:error, :invalid_segment}
  end

  defp validate_segment(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> validate_segment()
  end

  defp validate_segment(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> validate_segment()
  end

  defp validate_segment(_value), do: {:error, :invalid_segment}
end
