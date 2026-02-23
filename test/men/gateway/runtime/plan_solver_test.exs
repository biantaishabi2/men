defmodule Men.Gateway.Runtime.PlanSolverTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.Runtime.PlanSolver

  test "同组 score 并列时按 risk/depth/option_id 稳定 tie-break" do
    input = %{
      option_groups: %{
        "g1" => [
          %{option_id: "B", score: 0.9, risk: 0.2, depth: 2, source_priority: 1, feasible: true},
          %{option_id: "A", score: 0.9, risk: 0.1, depth: 3, source_priority: 1, feasible: true},
          %{option_id: "C", score: 0.9, risk: 0.1, depth: 4, source_priority: 1, feasible: true}
        ]
      },
      available_dependencies: []
    }

    result = PlanSolver.solve(input)

    assert result.selected_path["g1"].option_id == "A"
    assert result.selection_reason["g1"].reason == "selected_by_score_risk_depth_option_id"
    assert result.override_applied["g1"] == false
    assert result.fallback_triggered["g1"] == false
  end

  test "全部不可行且无 override 时按 source_priority fallback" do
    input = %{
      option_groups: %{
        "g1" => [
          %{
            option_id: "A",
            score: 0.9,
            risk: 0.1,
            depth: 1,
            source_priority: 10,
            feasible: false
          },
          %{option_id: "B", score: 0.8, risk: 0.1, depth: 1, source_priority: 20, feasible: false}
        ]
      }
    }

    result = PlanSolver.solve(input)

    assert result.selected_path["g1"].option_id == "B"
    assert result.fallback_triggered["g1"] == true
    assert result.override_applied["g1"] == false
    assert result.selection_reason["g1"].reason == "all_infeasible_fallback_by_source_priority"
  end

  test "全部不可行时 override 强制选路并输出 explain" do
    input = %{
      option_groups: %{
        "g1" => [
          %{
            option_id: "A",
            score: 0.2,
            risk: 0.1,
            depth: 1,
            source_priority: 1,
            feasible: false,
            requires: ["dep1"]
          },
          %{option_id: "B", score: 0.1, risk: 0.1, depth: 1, source_priority: 2, feasible: false}
        ]
      },
      override_option_id: "A",
      available_dependencies: []
    }

    result = PlanSolver.solve(input)

    assert result.selected_path["g1"].option_id == "A"
    assert result.override_applied["g1"] == true
    assert result.fallback_triggered["g1"] == false
    assert result.unmet_dependencies["g1"] == ["dep1"]
    assert result.selection_reason["g1"].reason == "all_infeasible_forced_override"
  end
end
