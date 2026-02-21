defmodule MenWeb.CacheBodyReader do
  @moduledoc """
  缓存原始请求体，供 webhook 验签使用。
  """

  def read_body(conn, opts) do
    case do_read_body(conn, opts, []) do
      {:ok, raw_body, conn} ->
        conn = Plug.Conn.assign(conn, :raw_body, raw_body)
        {:ok, raw_body, conn}

      {:error, _reason} = error ->
        error
    end
  end

  # 兼容分块请求体，避免大包体场景下丢失原始字节。
  defp do_read_body(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}

      {:more, chunk, conn} ->
        do_read_body(conn, opts, [chunk | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end
end
