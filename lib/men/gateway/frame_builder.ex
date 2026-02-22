defmodule Men.Gateway.FrameBuilder do
  @moduledoc """
  按需注入 FrameSnapshot sections，避免固定全量上下文污染。
  """

  alias Men.Gateway.Runtime.FrameSnapshotBuilder
  alias Men.Gateway.Runtime.FrameSnapshotBuilder.FrameSnapshot

  @default_sections [
    :goal,
    :policy,
    :current_focus,
    :next_candidates,
    :constraints,
    :recommendations,
    :state_ref
  ]

  @list_sections [:next_candidates, :constraints, :recommendations]

  @type section ::
          :goal
          | :policy
          | :current_focus
          | :next_candidates
          | :constraints
          | :recommendations
          | :state_ref
          | :generated_at
          | :debug_info

  @type t :: %{
          snapshot_type: FrameSnapshotBuilder.snapshot_type(),
          snapshot: FrameSnapshot.t(),
          sections: %{optional(section()) => term()}
        }

  @spec build(map(), keyword()) :: t()
  def build(runtime_state, opts \\ []) when is_map(runtime_state) and is_list(opts) do
    snapshot_type = Keyword.get(opts, :snapshot_type, :action_snapshot)
    sections = normalize_sections(Keyword.get(opts, :sections, @default_sections))
    debug? = Keyword.get(opts, :debug, false)

    snapshot =
      FrameSnapshotBuilder.build(runtime_state,
        snapshot_type: snapshot_type,
        debug: debug?
      )

    frame_sections =
      snapshot
      |> map_snapshot_by_type()
      |> pick_sections(sections)

    %{
      snapshot_type: snapshot.snapshot_type,
      snapshot: snapshot,
      sections: frame_sections
    }
  end

  defp normalize_sections(sections) when is_list(sections) do
    sections
    |> Enum.filter(&is_atom/1)
    |> Enum.uniq()
  end

  defp normalize_sections(_), do: @default_sections

  defp map_snapshot_by_type(%FrameSnapshot{snapshot_type: :idle_snapshot} = snapshot) do
    %{
      goal: snapshot.goal,
      policy: snapshot.policy,
      current_focus: snapshot.current_focus,
      next_candidates: snapshot.next_candidates,
      constraints: snapshot.constraints,
      recommendations: snapshot.recommendations,
      state_ref: snapshot.state_ref,
      generated_at: snapshot.generated_at,
      debug_info: snapshot.debug_info
    }
  end

  defp map_snapshot_by_type(%FrameSnapshot{snapshot_type: :action_snapshot} = snapshot) do
    high_priority = Enum.filter(snapshot.recommendations, &high_priority_recommendation?/1)

    %{
      goal: snapshot.goal,
      policy: snapshot.policy,
      current_focus: snapshot.current_focus,
      next_candidates: merge_action_candidates(snapshot.next_candidates, high_priority),
      constraints: snapshot.constraints,
      recommendations: [],
      state_ref: snapshot.state_ref,
      generated_at: snapshot.generated_at,
      debug_info: snapshot.debug_info
    }
  end

  defp map_snapshot_by_type(%FrameSnapshot{snapshot_type: :handoff_snapshot} = snapshot) do
    mapped_recommendations =
      Enum.map(snapshot.recommendations, fn recommendation ->
        recommendation
        |> Map.put_new(:source, :recommender)
        |> Map.put(:origin, :recommendations)
      end)

    %{
      goal: snapshot.goal,
      policy: snapshot.policy,
      current_focus: snapshot.current_focus,
      next_candidates: snapshot.next_candidates,
      constraints: snapshot.constraints,
      recommendations: mapped_recommendations,
      state_ref: snapshot.state_ref,
      generated_at: snapshot.generated_at,
      debug_info: snapshot.debug_info
    }
  end

  defp merge_action_candidates(next_candidates, recommendations) do
    recommendation_candidates =
      Enum.map(recommendations, fn recommendation ->
        %{
          id: "rec:" <> Integer.to_string(:erlang.phash2(recommendation)),
          title: Map.get(recommendation, :text),
          source: :recommendation
        }
      end)

    (recommendation_candidates ++ next_candidates)
    |> Enum.take(5)
  end

  defp high_priority_recommendation?(%{} = recommendation) do
    priority = Map.get(recommendation, :priority)
    priority in [:high, "high", :p0, "p0", 0, 1]
  end

  defp high_priority_recommendation?(_), do: false

  defp pick_sections(snapshot_map, sections) do
    Enum.reduce(sections, %{}, fn section, acc ->
      value = Map.get(snapshot_map, section, default_section_value(section))
      Map.put(acc, section, normalize_section_value(section, value))
    end)
  end

  defp normalize_section_value(section, nil) when section in @list_sections, do: []
  defp normalize_section_value(_section, value), do: value

  defp default_section_value(section) when section in @list_sections, do: []
  defp default_section_value(_section), do: nil
end
