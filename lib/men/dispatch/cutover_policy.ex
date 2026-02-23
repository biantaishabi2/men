defmodule Men.Dispatch.CutoverPolicy do
  @moduledoc """
  men->zcpg 灰度路由策略。

  决策顺序：
  1) 非 @ 消息直接忽略（硬门禁）
  2) 关闭 cutover 时走 legacy
  3) 打开 cutover 后仅 tenant 白名单走 zcpg
  """

  @type route :: :zcpg | :legacy | :ignore

  @spec route(map(), keyword()) :: route()
  def route(event, opts \\ []) when is_map(event) and is_list(opts) do
    cfg = Keyword.get(opts, :config, Application.get_env(:men, :zcpg_cutover, []))
    env = Keyword.get(opts, :env, config_env())

    if mention_required?(event) and not mentioned?(event) do
      :ignore
    else
      route_by_cutover(event, cfg, env)
    end
  end

  defp route_by_cutover(event, cfg, env) do
    enabled = Keyword.get(cfg, :enabled, false)
    env_override = Keyword.get(cfg, :env_override, false)
    effective_enabled = enabled or (env != :prod and env_override)

    if not effective_enabled do
      :legacy
    else
      tenant = extract_tenant(event)
      whitelist = normalize_whitelist(Keyword.get(cfg, :tenant_whitelist, []))

      if tenant != nil and MapSet.member?(whitelist, tenant) do
        :zcpg
      else
        :legacy
      end
    end
  end

  # 仅对钉钉默认开启 @ 门禁，避免影响不具备 @ 语义的通道。
  defp mention_required?(event) do
    metadata = Map.get(event, :metadata, %{})

    case map_value(metadata, :mention_required, nil) do
      value when is_boolean(value) -> value
      _ -> map_value(event, :channel, nil) == "dingtalk"
    end
  end

  defp mentioned?(event) do
    metadata = Map.get(event, :metadata, %{})

    case map_value(metadata, :mentioned, nil) do
      value when is_boolean(value) ->
        value

      _ ->
        event
        |> extract_content()
        |> contains_mention?()
    end
  end

  defp extract_content(event) do
    payload = Map.get(event, :payload)

    cond do
      is_binary(payload) ->
        payload

      is_map(payload) ->
        map_value(payload, :content, "")

      true ->
        ""
    end
  end

  defp contains_mention?(content) when is_binary(content), do: String.contains?(content, "@")
  defp contains_mention?(_), do: false

  defp extract_tenant(event) do
    payload = Map.get(event, :payload)
    metadata = Map.get(event, :metadata, %{})

    tenant =
      map_value(event, :tenant_id, nil) ||
        map_value(metadata, :tenant_id, nil) ||
        map_value(payload, :tenant_id, nil) ||
        payload_raw_tenant(payload)

    case tenant do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> nil
    end
  end

  defp payload_raw_tenant(payload) when is_map(payload) do
    payload
    |> map_value(:raw_payload, %{})
    |> case do
      raw when is_map(raw) ->
        map_value(raw, :tenant_id, nil) ||
          map_value(raw, :tenantId, nil) ||
          map_value(raw, :corpId, nil)

      _ ->
        nil
    end
  end

  defp payload_raw_tenant(_), do: nil

  defp normalize_whitelist(list) when is_list(list) do
    list
    |> Enum.map(fn
      value when is_binary(value) -> String.trim(value)
      value -> to_string(value)
    end)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_whitelist(_), do: MapSet.new()

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_value(_map, _key, default), do: default

  defp config_env do
    Application.get_env(:men, :env, config_env_fallback())
  end

  defp config_env_fallback do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      Mix.env()
    else
      :prod
    end
  end
end
