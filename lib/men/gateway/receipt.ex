defmodule Men.Gateway.Receipt do
  @moduledoc """
  Action 回执统一结构与落库/事件发布。
  """

  alias Men.Gateway.EventBus
  alias Men.Gateway.ReplStore

  @enforce_keys [
    :receipt_id,
    :run_id,
    :action_id,
    :status,
    :code,
    :message,
    :data,
    :retryable,
    :ts
  ]
  defstruct [
    :receipt_id,
    :run_id,
    :action_id,
    :status,
    :code,
    :message,
    :data,
    :retryable,
    :ts
  ]

  @type status :: :ok | :failed

  @type t :: %__MODULE__{
          receipt_id: binary(),
          run_id: binary(),
          action_id: binary(),
          status: status(),
          code: binary(),
          message: binary(),
          data: map(),
          retryable: boolean(),
          ts: integer()
        }

  @spec safe_new(map()) :: {:ok, t()} | {:error, term()}
  def safe_new(attrs) when is_map(attrs) do
    with {:ok, run_id} <- fetch_required_id(attrs, :run_id),
         {:ok, action_id} <- fetch_required_id(attrs, :action_id) do
      {:ok,
       %__MODULE__{
         receipt_id:
           Map.get(attrs, :receipt_id) ||
             Map.get(attrs, "receipt_id") ||
             build_receipt_id(run_id, action_id),
         run_id: run_id,
         action_id: action_id,
         status: normalize_status(Map.get(attrs, :status) || Map.get(attrs, "status")),
         code: normalize_binary(Map.get(attrs, :code) || Map.get(attrs, "code"), "UNKNOWN"),
         message: normalize_binary(Map.get(attrs, :message) || Map.get(attrs, "message"), "unknown"),
         data: normalize_data(Map.get(attrs, :data) || Map.get(attrs, "data") || %{}),
         retryable: Map.get(attrs, :retryable) == true or Map.get(attrs, "retryable") == true,
         ts: normalize_ts(Map.get(attrs, :ts) || Map.get(attrs, "ts"))
       }}
    end
  end

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    case safe_new(attrs) do
      {:ok, receipt} ->
        receipt

      {:error, reason} ->
        raise ArgumentError, "invalid receipt attrs: #{inspect(reason)}"
    end
  end

  @spec record(t(), keyword()) :: {:ok, :stored | :duplicate}
  def record(%__MODULE__{} = receipt, opts \\ []) do
    session_key = Keyword.get(opts, :session_key, "global")
    repl_store_opts = Keyword.get(opts, :repl_store_opts, [])
    event_topic = Keyword.get(opts, :event_topic, "gateway_events")

    actor = %{role: :system, session_key: session_key}
    key = receipt_key(session_key, receipt)

    case ReplStore.put(
           actor,
           key,
           Map.from_struct(receipt),
           Keyword.merge(repl_store_opts,
             policy: allow_all_policy(),
             version: 0,
             context: %{type: "action_receipt", session_key: session_key}
           )
         ) do
      {:ok, :stored} ->
        :ok =
          EventBus.publish(event_topic, %{
            type: "action_receipt",
            session_key: session_key,
            run_id: receipt.run_id,
            action_id: receipt.action_id,
            receipt: Map.from_struct(receipt)
          })

        {:ok, :stored}

      {:ok, :idempotent} ->
        {:ok, :duplicate}

      {:ok, :older_drop} ->
        {:ok, :duplicate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec receipt_key(binary(), t()) :: binary()
  def receipt_key(session_key, %__MODULE__{} = receipt) when is_binary(session_key) do
    "receipt." <> session_key <> "." <> receipt.run_id <> "." <> receipt.action_id
  end

  defp build_receipt_id(run_id, action_id) do
    "rcpt-" <> run_id <> "-" <> action_id
  end

  defp normalize_status(value) when value in [:ok, "ok", :success, "success"], do: :ok
  defp normalize_status(_), do: :failed

  defp normalize_binary(value, _fallback) when is_binary(value) and value != "", do: value
  defp normalize_binary(value, _fallback) when is_atom(value), do: Atom.to_string(value)
  defp normalize_binary(_value, fallback), do: fallback

  defp normalize_data(%{} = data), do: data
  defp normalize_data(data), do: %{value: data}

  defp normalize_ts(ts) when is_integer(ts) and ts > 0, do: ts
  defp normalize_ts(_), do: System.system_time(:millisecond)

  defp fetch_required_id(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      {:error, {:invalid_required_field, key}}
    end
  end

  defp allow_all_policy do
    %{
      acl: %{
        "system" => %{"read" => [""], "write" => [""]}
      },
      policy_version: "receipt-v1"
    }
  end
end
