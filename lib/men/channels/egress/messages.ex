defmodule Men.Channels.Egress.Messages.FinalMessage do
  @moduledoc """
  出站最终消息结构。
  """

  @enforce_keys [:session_key, :content]
  defstruct [:session_key, :content, metadata: %{}]

  @type t :: %__MODULE__{
          session_key: String.t(),
          content: String.t(),
          metadata: map()
        }

  @spec new(String.t(), String.t(), map()) :: t()
  def new(session_key, content, metadata \\ %{}) do
    Men.Channels.Egress.Messages.final_message(session_key, content, metadata)
  end
end

defmodule Men.Channels.Egress.Messages.ErrorMessage do
  @moduledoc """
  出站错误消息结构。
  """

  @enforce_keys [:session_key, :reason]
  defstruct [:session_key, :reason, code: nil, metadata: %{}]

  @type t :: %__MODULE__{
          session_key: String.t(),
          reason: String.t(),
          code: String.t() | nil,
          metadata: map()
        }

  @spec new(String.t(), String.t(), String.t() | nil, map()) :: t()
  def new(session_key, reason, code \\ nil, metadata \\ %{}) do
    Men.Channels.Egress.Messages.error_message(session_key, reason, code, metadata)
  end
end

defmodule Men.Channels.Egress.Messages do
  @moduledoc """
  出站消息统一构造工具。
  """

  alias Men.Channels.Egress.Messages.{ErrorMessage, EventMessage, FinalMessage}

  @required_metadata_keys [:run_id, :session_key, :request_id, :seq, :timestamp]

  @spec build_metadata(map() | nil, map() | nil) ::
          {:ok, map()} | {:error, {:missing_metadata, atom()}}
  def build_metadata(base_metadata, required_metadata) do
    metadata =
      base_metadata
      |> normalize_metadata()
      |> Map.merge(normalize_metadata(required_metadata))

    case Enum.find(@required_metadata_keys, fn key ->
           value = metadata_value(metadata, key)
           is_nil(value) or value == ""
         end) do
      nil -> {:ok, metadata}
      key -> {:error, {:missing_metadata, key}}
    end
  end

  @spec event_message(atom() | String.t(), term(), map() | nil, map() | nil) ::
          {:ok, EventMessage.t()} | {:error, term()}
  def event_message(event_type, payload, metadata \\ %{}, required_metadata \\ %{}) do
    EventMessage.new(event_type, payload, metadata, required_metadata)
  end

  @spec final_message(String.t(), String.t(), map()) :: FinalMessage.t()
  def final_message(session_key, content, metadata \\ %{}) do
    %FinalMessage{
      session_key: session_key,
      content: content,
      metadata: normalize_metadata(metadata)
    }
  end

  @spec error_message(String.t(), String.t(), String.t() | nil, map()) :: ErrorMessage.t()
  def error_message(session_key, reason, code \\ nil, metadata \\ %{}) do
    %ErrorMessage{
      session_key: session_key,
      reason: reason,
      code: code,
      metadata: normalize_metadata(metadata)
    }
  end

  @spec metadata_value(map(), atom(), term()) :: term()
  def metadata_value(metadata, key, default \\ nil)

  def metadata_value(metadata, key, default) when is_map(metadata) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key), default))
  end

  def metadata_value(_metadata, _key, default), do: default

  defp normalize_metadata(%{} = metadata), do: metadata
  defp normalize_metadata(_), do: %{}
end

defmodule Men.Channels.Egress.Messages.EventMessage do
  @moduledoc """
  出站统一事件结构。
  """

  alias Men.Channels.Egress.Messages

  @enforce_keys [:event_type, :payload, :metadata]
  defstruct [:event_type, :payload, metadata: %{}]

  @type event_type :: :delta | :final | :error

  @type t :: %__MODULE__{
          event_type: event_type(),
          payload: term(),
          metadata: map()
        }

  @spec new(atom() | String.t(), term(), map() | nil, map() | nil) ::
          {:ok, t()} | {:error, term()}
  def new(event_type, payload, metadata \\ %{}, required_metadata \\ %{}) do
    with {:ok, normalized_event_type} <- normalize_event_type(event_type),
         {:ok, final_metadata} <- Messages.build_metadata(metadata, required_metadata) do
      {:ok,
       %__MODULE__{
         event_type: normalized_event_type,
         payload: payload,
         metadata: final_metadata
       }}
    end
  end

  defp normalize_event_type(event_type) when is_atom(event_type) do
    if event_type in [:delta, :final, :error],
      do: {:ok, event_type},
      else: {:error, {:invalid_event_type, event_type}}
  end

  defp normalize_event_type(event_type) when is_binary(event_type) do
    event_type
    |> String.trim()
    |> String.downcase()
    |> case do
      "delta" -> {:ok, :delta}
      "final" -> {:ok, :final}
      "error" -> {:ok, :error}
      other -> {:error, {:invalid_event_type, other}}
    end
  end

  defp normalize_event_type(other), do: {:error, {:invalid_event_type, other}}
end
