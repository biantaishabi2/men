defmodule Men.Gateway.Runtime.PlanSolver do
  @moduledoc """
  Plan 图 AND-OR 选路纯函数求解器。
  """

  @spec solve(map()) :: map()
  def solve(input) when is_map(input) do
    groups = Map.get(input, :option_groups, %{})
    override = Map.get(input, :override_option_id)

    available_deps =
      input
      |> Map.get(:available_dependencies, [])
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    group_ids = groups |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

    {selected_path, unmet_dependencies, explain} =
      Enum.reduce(group_ids, {%{}, %{}, init_explain()}, fn group_id,
                                                            {path_acc, unmet_acc, explain_acc} ->
        options =
          groups
          |> group_options(group_id)
          |> Enum.map(&normalize_option/1)

        selected_ids =
          path_acc |> Map.values() |> Enum.map(&Map.get(&1, :option_id)) |> MapSet.new()

        feasible =
          Enum.filter(options, fn option ->
            feasible_option?(option, available_deps, selected_ids)
          end)

        result =
          cond do
            feasible != [] ->
              selected = pick_best(feasible)
              %{selected: selected, reason: :feasible_best, override: false, fallback: false}

            true ->
              choose_non_feasible(options, group_id, override)
          end

        selected = result.selected

        updated_unmet =
          Map.put(
            unmet_acc,
            group_id,
            unresolved_requires(selected, available_deps, selected_ids)
          )

        updated_path = Map.put(path_acc, group_id, selected)
        updated_explain = append_explain(explain_acc, group_id, selected, result)

        {updated_path, updated_unmet, updated_explain}
      end)

    %{
      selected_path: selected_path,
      unmet_dependencies: unmet_dependencies,
      selection_reason: explain.selection_reason,
      override_applied: explain.override_applied,
      fallback_triggered: explain.fallback_triggered
    }
  end

  defp init_explain do
    %{selection_reason: %{}, override_applied: %{}, fallback_triggered: %{}}
  end

  defp append_explain(explain, group_id, selected, result) do
    reason =
      case result.reason do
        :feasible_best -> "selected_by_score_risk_depth_option_id"
        :forced_override -> "all_infeasible_forced_override"
        :fallback_priority -> "all_infeasible_fallback_by_source_priority"
      end

    explain
    |> put_in([:selection_reason, group_id], %{
      option_id: selected.option_id,
      reason: reason,
      forced: result.override,
      fallback: result.fallback
    })
    |> put_in([:override_applied, group_id], result.override)
    |> put_in([:fallback_triggered, group_id], result.fallback)
  end

  defp choose_non_feasible(options, group_id, override) do
    override_id = resolve_override(override, group_id)

    cond do
      is_binary(override_id) and override_id != "" ->
        forced = Enum.find(options, fn option -> option.option_id == override_id end)

        selected =
          forced ||
            options
            |> Enum.sort_by(fn option -> option.option_id end)
            |> List.first() ||
            default_option(override_id)

        %{selected: selected, reason: :forced_override, override: true, fallback: false}

      true ->
        selected =
          options
          |> Enum.sort_by(fn option ->
            [-option.source_priority, option.option_id]
          end)
          |> List.first() || default_option("")

        %{selected: selected, reason: :fallback_priority, override: false, fallback: true}
    end
  end

  defp resolve_override(override, group_id) do
    cond do
      is_binary(override) ->
        override

      is_map(override) ->
        Map.get(override, group_id) || Map.get(override, String.to_atom(group_id))

      true ->
        nil
    end
  end

  defp group_options(groups, group_id) do
    groups
    |> Map.get(group_id, Map.get(groups, String.to_atom(group_id), []))
    |> List.wrap()
  end

  defp pick_best(options) do
    Enum.min_by(options, fn option ->
      [-option.score, option.risk, option.depth, option.option_id]
    end)
  end

  defp feasible_option?(option, available_deps, selected_ids) do
    declared_feasible = Map.get(option, :feasible, true)

    declared_feasible and
      Enum.all?(option.requires, fn dep ->
        MapSet.member?(available_deps, dep) || MapSet.member?(selected_ids, dep)
      end)
  end

  defp unresolved_requires(option, available_deps, selected_ids) do
    option.requires
    |> Enum.reject(fn dep ->
      MapSet.member?(available_deps, dep) || MapSet.member?(selected_ids, dep)
    end)
    |> Enum.sort()
  end

  defp normalize_option(option) do
    %{
      option_id: to_string(Map.get(option, :option_id) || Map.get(option, "option_id") || ""),
      score: normalize_float(Map.get(option, :score) || Map.get(option, "score") || 0.0),
      risk: normalize_float(Map.get(option, :risk) || Map.get(option, "risk") || 0.0),
      depth: normalize_int(Map.get(option, :depth) || Map.get(option, "depth") || 0),
      source_priority:
        normalize_int(
          Map.get(option, :source_priority) || Map.get(option, "source_priority") || 0
        ),
      feasible: Map.get(option, :feasible, Map.get(option, "feasible", true)),
      requires:
        option
        |> Map.get(:requires, Map.get(option, "requires", []))
        |> List.wrap()
        |> Enum.map(&to_string/1)
    }
  end

  defp default_option(option_id) do
    %{
      option_id: option_id,
      score: 0.0,
      risk: 9999.0,
      depth: 9999,
      source_priority: -1,
      feasible: false,
      requires: []
    }
  end

  defp normalize_float(value) when is_integer(value), do: value * 1.0
  defp normalize_float(value) when is_float(value), do: value
  defp normalize_float(_), do: 0.0

  defp normalize_int(value) when is_integer(value), do: value
  defp normalize_int(value) when is_float(value), do: trunc(value)
  defp normalize_int(_), do: 0
end
