defmodule MenWeb.InternalAuth do
  @moduledoc """
  internal 接口统一 token 鉴权。
  """

  import Plug.Conn

  @spec authorize(Plug.Conn.t(), keyword()) :: :ok | {:error, :missing_internal_token | :unauthorized}
  def authorize(conn, opts \\ []) do
    with {:ok, expected_token} <- fetch_expected_token(opts),
         {:ok, presented_token} <- fetch_presented_token(conn),
         true <- Plug.Crypto.secure_compare(expected_token, presented_token) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :unauthorized}
    end
  end

  defp fetch_expected_token(opts) do
    config = Keyword.get(opts, :config, [])
    env_keys = Keyword.get(opts, :env_keys, ["MEN_INTERNAL_TOKEN", "DINGTALK_STREAM_INTERNAL_TOKEN"])

    config_token = Keyword.get(config, :internal_token)

    env_token =
      env_keys
      |> Enum.find_value(fn key ->
        value = System.get_env(key)
        if is_binary(value) and value != "", do: value, else: nil
      end)

    token = config_token || env_token

    if is_binary(token) and token != "" do
      {:ok, token}
    else
      {:error, :missing_internal_token}
    end
  end

  defp fetch_presented_token(conn) do
    from_header = List.first(get_req_header(conn, "x-men-internal-token"))
    token = from_header || bearer_token(conn)

    if is_binary(token) and token != "" do
      {:ok, token}
    else
      {:error, :unauthorized}
    end
  end

  defp bearer_token(conn) do
    case List.first(get_req_header(conn, "authorization")) do
      "Bearer " <> token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end
end
