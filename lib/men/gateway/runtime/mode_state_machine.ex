defmodule Men.Gateway.Runtime.ModeStateMachine do
  @moduledoc """
  Mode Policy Advisor：根据快照输出模式建议。

  默认只给建议，不直接强制切换主流程模式。
  当 `apply_mode?` 为 true 时，才会把建议应用为实际迁移。
  """

  require Logger

  @type mode :: :research | :execute
  @type recommended_mode :: :research | :execute | :hold

  @type context :: %{
          required(:stable_graph_ticks) => non_neg_integer(),
          required(:tick) => non_neg_integer(),
          required(:last_reason) => atom() | nil
        }

  @type decision_meta :: %{
          required(:transition?) => boolean(),
          required(:from_mode) => mode(),
          required(:to_mode) => mode(),
          required(:recommended_mode) => recommended_mode(),
          required(:apply_mode?) => boolean(),
          required(:reason) => atom(),
          required(:priority) => atom() | nil,
          required(:tick) => non_neg_integer(),
          required(:cooldown_remaining) => non_neg_integer(),
          required(:hysteresis_state) => map(),
          required(:warnings) => [atom()]
        }

  @defaults %{
    enter_threshold: 0.75,
    graph_stable_max: 0.05,
    stable_window_ticks: 3,
    info_insufficient_ratio: 0.30,
    apply_mode?: false
  }

  @required_keys Map.keys(@defaults)

  @spec initial_context() :: context()
  def initial_context do
    %{
      stable_graph_ticks: 0,
      tick: 0,
      last_reason: nil
    }
  end

  @spec decide(mode(), map(), context(), map() | keyword()) ::
          {mode(), context(), decision_meta()}
  def decide(current_mode, snapshot, context, overrides \\ %{})
      when current_mode in [:research, :execute] and is_map(snapshot) do
    config = resolve_config(overrides)
    tick = context.tick + 1

    stable_graph_ticks =
      update_stable_graph_ticks(context.stable_graph_ticks, snapshot, config.graph_stable_max)

    {recommended_mode, reason, priority} =
      advise(current_mode, snapshot, stable_graph_ticks, config)

    apply_mode? = truthy?(Map.get(config, :apply_mode?, false))

    next_mode =
      if apply_mode? and recommended_mode in [:research, :execute] and
           recommended_mode != current_mode do
        recommended_mode
      else
        current_mode
      end

    transition? = next_mode != current_mode

    next_context = %{
      stable_graph_ticks: stable_graph_ticks,
      tick: tick,
      last_reason: reason
    }

    meta = %{
      transition?: transition?,
      from_mode: current_mode,
      to_mode: next_mode,
      recommended_mode: recommended_mode,
      apply_mode?: apply_mode?,
      reason: reason,
      priority: priority,
      tick: tick,
      cooldown_remaining: 0,
      hysteresis_state: %{
        enter_threshold: config.enter_threshold,
        confidence: normalize_float(Map.get(snapshot, :key_claim_confidence, 0.0)),
        stable_graph_ticks: stable_graph_ticks
      },
      warnings: []
    }

    {next_mode, next_context, meta}
  end

  defp advise(:research, snapshot, stable_graph_ticks, config) do
    blocking_count = normalize_non_neg_int(Map.get(snapshot, :blocking_count, 0))
    confidence = normalize_float(Map.get(snapshot, :key_claim_confidence, 0.0))
    execute_compilable = truthy?(Map.get(snapshot, :execute_compilable))

    cond do
      blocking_count > 0 ->
        {:hold, :blocking_present, :low}

      confidence < config.enter_threshold ->
        {:hold, :confidence_below_enter_threshold, :low}

      stable_graph_ticks < config.stable_window_ticks ->
        {:hold, :graph_not_stable_yet, :low}

      not execute_compilable ->
        {:hold, :execute_not_ready, :low}

      true ->
        {:execute, :evidence_and_compile_ready, :normal}
    end
  end

  defp advise(:execute, snapshot, _stable_graph_ticks, config) do
    cond do
      truthy?(Map.get(snapshot, :premise_invalidated)) ->
        {:research, :premise_invalidated, :high}

      truthy?(Map.get(snapshot, :external_mutation)) ->
        {:research, :external_mutation, :medium}

      info_insufficient?(snapshot, config.info_insufficient_ratio) ->
        {:research, :info_insufficient, :low}

      true ->
        {:hold, :execute_stable, nil}
    end
  end

  defp update_stable_graph_ticks(current_ticks, snapshot, graph_stable_max) do
    change_rate = normalize_float(Map.get(snapshot, :graph_change_rate, 1.0))

    if change_rate < graph_stable_max do
      current_ticks + 1
    else
      0
    end
  end

  defp info_insufficient?(snapshot, threshold) do
    total = normalize_non_neg_int(Map.get(snapshot, :total_critical_paths, 0))
    uncovered = normalize_non_neg_int(Map.get(snapshot, :uncovered_critical_paths, 0))

    if total <= 0 do
      false
    else
      uncovered / total > threshold
    end
  end

  defp resolve_config(overrides) do
    env =
      :men
      |> Application.get_env(__MODULE__, %{})
      |> normalize_config_source()

    override_map = normalize_config_source(overrides)

    merged =
      @defaults
      |> Map.merge(env)
      |> Map.merge(override_map)

    Enum.reduce(@required_keys, merged, fn key, acc ->
      if Map.has_key?(acc, key) and not is_nil(Map.get(acc, key)) do
        acc
      else
        warn_missing_config(key, Map.get(@defaults, key))
        Map.put(acc, key, Map.get(@defaults, key))
      end
    end)
  end

  defp warn_missing_config(key, fallback) do
    warned = Process.get({__MODULE__, :missing_config_warned}, MapSet.new())

    if MapSet.member?(warned, key) do
      :ok
    else
      Logger.warning(
        "mode_policy_advisor config missing key=#{key}, fallback_default=#{inspect(fallback)}"
      )

      Process.put({__MODULE__, :missing_config_warned}, MapSet.put(warned, key))
    end
  end

  defp normalize_config_source(source) when is_list(source), do: Map.new(source)
  defp normalize_config_source(source) when is_map(source), do: source
  defp normalize_config_source(_), do: %{}

  defp normalize_non_neg_int(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_neg_int(_), do: 0

  defp normalize_float(value) when is_integer(value), do: value * 1.0
  defp normalize_float(value) when is_float(value), do: value
  defp normalize_float(_), do: 0.0

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false
end
