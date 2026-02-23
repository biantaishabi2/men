defmodule Men.Gateway.Runtime.Telemetry do
  @moduledoc """
  JIT 编排 Telemetry v1 契约。
  """

  @event_prefix [:men, :gateway, :runtime, :jit, :v1]
  @contract_version "v1"
  @compatible_minor_window 2
  @required_fields [
    :trace_id,
    :session_id,
    :flag_state,
    :advisor_decision,
    :snapshot_action,
    :rollback_reason
  ]

  @type event_name ::
          :graph_invoked
          | :advisor_decided
          | :snapshot_generated
          | :rollback_triggered
          | :degraded
          | :cycle_completed

  @spec event_prefix() :: [atom()]
  def event_prefix, do: @event_prefix

  @spec contract_version() :: binary()
  def contract_version, do: @contract_version

  @spec compatible_minor_window() :: pos_integer()
  def compatible_minor_window, do: @compatible_minor_window

  @spec required_fields() :: [atom()]
  def required_fields, do: @required_fields

  @spec emit(event_name(), map(), map()) :: :ok | {:error, {:missing_fields, [atom()]}}
  def emit(event_name, metadata, measurements \\ %{count: 1})
      when is_atom(event_name) and is_map(metadata) and is_map(measurements) do
    normalized = normalize_metadata(metadata)

    with :ok <- validate_required(normalized) do
      :telemetry.execute(@event_prefix ++ [event_name], measurements, normalized)
      :ok
    end
  rescue
    _ -> :ok
  end

  @spec validate_required(map()) :: :ok | {:error, {:missing_fields, [atom()]}}
  def validate_required(metadata) when is_map(metadata) do
    missing_fields =
      Enum.reject(@required_fields, fn field ->
        Map.has_key?(metadata, field)
      end)

    if missing_fields == [] do
      :ok
    else
      {:error, {:missing_fields, missing_fields}}
    end
  end

  defp normalize_metadata(metadata) do
    metadata
    |> Map.put_new(:contract_version, @contract_version)
    |> Map.put_new(:compat_minor_window, @compatible_minor_window)
    |> Map.update(:flag_state, :jit_enabled, &normalize_flag_state/1)
    |> Map.update(:advisor_decision, :hold, &normalize_decision/1)
    |> Map.update(:snapshot_action, :injected, &normalize_snapshot_action/1)
    |> Map.put_new(:rollback_reason, nil)
  end

  defp normalize_flag_state(flag) when flag in [:jit_enabled, :jit_disabled, :smoke_mode],
    do: flag

  defp normalize_flag_state(_), do: :jit_enabled

  defp normalize_decision(decision) when is_atom(decision), do: decision
  defp normalize_decision("research"), do: :research
  defp normalize_decision("execute"), do: :execute
  defp normalize_decision("hold"), do: :hold
  defp normalize_decision("fixed_path"), do: :fixed_path
  defp normalize_decision(_), do: :hold

  defp normalize_snapshot_action(action) when is_atom(action), do: action
  defp normalize_snapshot_action("injected"), do: :injected
  defp normalize_snapshot_action("rebuilt"), do: :rebuilt
  defp normalize_snapshot_action("fixed_path"), do: :fixed_path
  defp normalize_snapshot_action("pending"), do: :pending
  defp normalize_snapshot_action(_), do: :injected
end
