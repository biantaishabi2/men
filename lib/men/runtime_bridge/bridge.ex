defmodule Men.RuntimeBridge.Bridge do
  @moduledoc """
  Runtime Bridge 契约。
  """

  alias Men.RuntimeBridge.{ErrorResponse, Request, Response}

  @callback call(Request.t(), opts :: keyword()) ::
              {:ok, Response.t()} | {:error, ErrorResponse.t()}
end
