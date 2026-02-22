defmodule Men.Gateway.Runtime.ModeStateMachine do
  @moduledoc """
  模式切换状态机：基于每轮信号快照计算下一模式与决策元数据。
  """

  require Logger

  @type mode :: :research | :plan | :execute

  @type context :: %{
          required(:stable_graph_ticks) => non_neg_integer(),
          required(:cooldown_remaining) => non_neg_integer(),
          required(:tick) => non_neg_integer(),
          required(:transition_ticks) => [non_neg_integer()],
          required(:safety_mode) => boolean(),
          required(:recovery_remaining) => non_neg_integer(),
          required(:last_reason) => atom() | nil
        }

  @type decision_meta :: %{
          required(:transition?) => boolean(),
          required(:from_mode) => mode(),
          required(:to_mode) => mode(),
          required(:reason) => atom(),
          required(:priority) => atom() | nil,
          required(:tick) => non_neg_integer(),
          required(:cooldown_remaining) => non_neg_integer(),
          required(:hysteresis_state) => map(),
          required(:warnings) => [atom()],
          required(:safety_mode) => boolean()
        }

  @defaults %{
    enter_threshold: 0.75,
    exit_threshold: 0.60,
    graph_stable_max: 0.05,
    stable_window_ticks: 3,
    cooldown_ticks: 3,
    info_insufficient_ratio: 0.30,
    churn_window_ticks: 8,
    churn_max_transitions: 4,
    research_only_recovery_ticks: 6
  }

  @required_keys Map.keys(@defaults)

  @spec initial_context() :: context()
  def initial_context do
    %{
      stable_graph_ticks: 0,
      cooldown_remaining: 0,
      tick: 0,
      transition_ticks: [],
      safety_mode: false,
      recovery_remaining: 0,
      last_reason: nil
    }
  end

  @spec decide(mode(), map(), context(), map() | keyword()) ::
          {mode(), context(), decision_meta()}
  def decide(current_mode, snapshot, context, overrides \\ %{})
      when current_mode in [:research, :plan, :execute] and is_map(snapshot) do
    config = resolve_config(overrides)
    tick = context.tick + 1

    stable_graph_ticks =
      update_stable_graph_ticks(context.stable_graph_ticks, snapshot, config.graph_stable_max)

    context =
      context
      |> Map.put(:tick, tick)
      |> Map.put(:stable_graph_ticks, stable_graph_ticks)

    {current_mode, context, safety_reason} = maybe_recover_safety_mode(current_mode, context)

    {target_mode, reason, priority} =
      if context.safety_mode do
        {:research, :research_only_safety_mode, :safety}
      else
        decide_by_mode(current_mode, snapshot, context, config)
      end

    {next_mode, cooldown_remaining, final_reason, final_priority} =
      apply_cooldown_guard(current_mode, target_mode, reason, priority, context, config)

    transition? = next_mode != current_mode

    {context, warnings} =
      context
      |> Map.put(:cooldown_remaining, cooldown_remaining)
      |> Map.put(:last_reason, final_reason)
      |> maybe_record_transition(transition?, tick, config)
      |> maybe_enter_safety_mode(transition?, next_mode, tick, config)

    reason = if is_nil(safety_reason), do: final_reason, else: safety_reason

    meta = %{
      transition?: transition?,
      from_mode: current_mode,
      to_mode: next_mode,
      reason: reason,
      priority: final_priority,
      tick: tick,
      cooldown_remaining: context.cooldown_remaining,
      hysteresis_state: %{
        enter_threshold: config.enter_threshold,
        exit_threshold: config.exit_threshold,
        confidence: normalize_float(Map.get(snapshot, :key_claim_confidence, 0.0)),
        stable_graph_ticks: stable_graph_ticks
      },
      warnings: warnings,
      safety_mode: context.safety_mode
    }

    {next_mode, context, meta}
  end

  defp decide_by_mode(:research, snapshot, context, config) do
    blocking_count = normalize_non_neg_int(Map.get(snapshot, :blocking_count, 0))
    confidence = normalize_float(Map.get(snapshot, :key_claim_confidence, 0.0))

    cond do
      blocking_count > 0 ->
        {:research, :blocking_present, nil}

      confidence < config.enter_threshold ->
        {:research, :confidence_below_enter_threshold, nil}

      context.stable_graph_ticks < config.stable_window_ticks ->
        {:research, :graph_not_stable_yet, nil}

      true ->
        {:plan, :confidence_and_stability_satisfied, :normal}
    end
  end

  defp decide_by_mode(:plan, snapshot, _context, config) do
    blocking_count = normalize_non_neg_int(Map.get(snapshot, :blocking_count, 0))

    cond do
      blocking_count > 0 ->
        {:research, :blocking_present, :low}

      confidence_below_exit_threshold?(snapshot, config.exit_threshold) ->
        {:research, :confidence_below_exit_threshold, :low}

      truthy?(Map.get(snapshot, :plan_selected)) and
          truthy?(Map.get(snapshot, :execute_compilable)) ->
        {:execute, :plan_ready_for_execution, :normal}

      true ->
        {:plan, :plan_not_ready_for_execution, nil}
    end
  end

  defp decide_by_mode(:execute, snapshot, _context, config) do
    cond do
      truthy?(Map.get(snapshot, :premise_invalidated)) ->
        {:research, :premise_invalidated, :high}

      truthy?(Map.get(snapshot, :external_mutation)) ->
        {:research, :external_mutation, :medium}

      info_insufficient?(snapshot, config.info_insufficient_ratio) ->
        {:research, :info_insufficient, :low}

      true ->
        {:execute, :execute_stable, nil}
    end
  end

  # 驻留期仅抑制反向回退，前提失效属于高优先级可强制突破。
  defp apply_cooldown_guard(current_mode, target_mode, reason, priority, context, config) do
    in_cooldown = context.cooldown_remaining > 0
    reverse? = reverse_transition?(current_mode, target_mode)

    cond do
      current_mode != target_mode and reason == :premise_invalidated ->
        {target_mode, config.cooldown_ticks, reason, priority}

      current_mode != target_mode and in_cooldown and reverse? ->
        {current_mode, context.cooldown_remaining - 1, :cooldown_blocked, :suppressed}

      current_mode != target_mode ->
        {target_mode, config.cooldown_ticks, reason, priority}

      in_cooldown ->
        {current_mode, context.cooldown_remaining - 1, reason, priority}

      true ->
        {current_mode, 0, reason, priority}
    end
  end

  defp reverse_transition?(:execute, :research), do: true
  defp reverse_transition?(:plan, :research), do: true
  defp reverse_transition?(:execute, :plan), do: true
  defp reverse_transition?(_, _), do: false

  defp maybe_recover_safety_mode(mode, %{safety_mode: false} = context), do: {mode, context, nil}

  defp maybe_recover_safety_mode(
         _mode,
         %{safety_mode: true, recovery_remaining: remaining} = context
       )
       when remaining > 1 do
    {
      :research,
      %{context | recovery_remaining: remaining - 1},
      :research_only_safety_mode
    }
  end

  defp maybe_recover_safety_mode(_mode, %{safety_mode: true} = context) do
    {
      :research,
      %{context | safety_mode: false, recovery_remaining: 0},
      :research_only_recovered
    }
  end

  defp maybe_record_transition(context, false, _tick, _config), do: {context, []}

  defp maybe_record_transition(context, true, tick, config) do
    min_tick = tick - config.churn_window_ticks + 1

    transition_ticks =
      [tick | context.transition_ticks]
      |> Enum.filter(&(&1 >= min_tick))

    {%{context | transition_ticks: transition_ticks}, []}
  end

  defp maybe_enter_safety_mode({context, warnings}, false, _mode, _tick, _config),
    do: {context, warnings}

  defp maybe_enter_safety_mode({context, warnings}, true, _mode, _tick, config) do
    if length(context.transition_ticks) > config.churn_max_transitions do
      {
        %{
          context
          | safety_mode: true,
            recovery_remaining: config.research_only_recovery_ticks,
            last_reason: :research_only_safety_mode
        },
        [:churn_limit_reached | warnings]
      }
    else
      {context, warnings}
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

  defp confidence_below_exit_threshold?(snapshot, exit_threshold) do
    case Map.fetch(snapshot, :key_claim_confidence) do
      {:ok, confidence} -> normalize_float(confidence) < exit_threshold
      :error -> false
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

    should_warn_env? = map_size(env) > 0

    Enum.reduce(@required_keys, merged, fn key, acc ->
      configured_in_env? = Map.has_key?(env, key)
      configured_in_override? = Map.has_key?(override_map, key)
      nil_override? = Map.has_key?(override_map, key) and is_nil(Map.get(override_map, key))

      cond do
        nil_override? ->
          warn_missing_config(key, Map.get(@defaults, key))
          Map.put(acc, key, Map.get(@defaults, key))

        should_warn_env? and not configured_in_env? and not configured_in_override? ->
          warn_missing_config(key, Map.get(@defaults, key))
          Map.put(acc, key, Map.get(@defaults, key))

        true ->
          acc
      end
    end)
  end

  defp warn_missing_config(key, fallback) do
    warned = Process.get({__MODULE__, :missing_config_warned}, MapSet.new())

    if MapSet.member?(warned, key) do
      :ok
    else
      Logger.warning(
        "mode_state_machine config missing key=#{key}, fallback_default=#{inspect(fallback)}"
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
