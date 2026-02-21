defmodule MenWeb.Plugs.RawBodyReader do
  @moduledoc false

  def read_body(conn, opts), do: read_body_chunks(conn, opts, "")

  defp read_body_chunks(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        raw_body = acc <> body
        {:ok, raw_body, Plug.Conn.assign(conn, :raw_body, raw_body)}

      {:more, chunk, conn} ->
        read_body_chunks(conn, opts, acc <> chunk)
    end
  end
end
