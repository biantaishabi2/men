defmodule Men.Gateway.Runtime.FrameSnapshotBuilder do
  @moduledoc """
  统一构建 runtime frame 最小快照。
  """

  defmodule FrameSnapshot do
    @moduledoc """
    Frame 快照契约。
    """

    @enforce_keys [
      :snapshot_type,
      :goal,
      :policy,
      :current_focus,
      :next_candidates,
      :constraints,
      :recommendations,
      :state_ref,
      :generated_at,
      :debug_info
    ]
    defstruct [
      :snapshot_type,
      :goal,
      :policy,
      :current_focus,
      :next_candidates,
      :constraints,
      :recommendations,
      :state_ref,
      :generated_at,
      :debug_info
    ]

    @type t :: %__MODULE__{
            snapshot_type: :idle_snapshot | :action_snapshot | :handoff_snapshot,
            goal: binary() | nil,
            policy: map() | nil,
            current_focus: map() | binary() | nil,
            next_candidates: [map()],
            constraints: [map()],
            recommendations: [map()],
            state_ref: map(),
            generated_at: integer(),
            debug_info: map() | nil
          }
  end

  @snapshot_types [:idle_snapshot, :action_snapshot, :handoff_snapshot]

  @focus_max_chars 200
  @focus_refs_max 3
  @candidates_max 5
  @active_constraints_max 3
  @recommendations_max 2
  @recommendation_text_max 150

  @type snapshot_type :: :idle_snapshot | :action_snapshot | :handoff_snapshot

  @spec build(map(), keyword()) :: FrameSnapshot.t()
  def build(runtime_state, opts \\ []) when is_map(runtime_state) and is_list(opts) do
    snapshot_type = normalize_snapshot_type(Keyword.get(opts, :snapshot_type, :action_snapshot))
    debug? = Keyword.get(opts, :debug, false)

    base = %FrameSnapshot{
      snapshot_type: snapshot_type,
      goal: extract_goal(runtime_state),
      policy: extract_policy(runtime_state),
      current_focus: extract_current_focus(runtime_state),
      next_candidates: extract_next_candidates(runtime_state),
      constraints: extract_constraints(runtime_state),
      recommendations: extract_recommendations(runtime_state),
      state_ref: extract_state_ref(runtime_state),
      generated_at: System.system_time(:millisecond),
      debug_info: build_debug_info(runtime_state, debug?)
    }

    shape_by_type(base)
  end

  defp shape_by_type(%FrameSnapshot{snapshot_type: :idle_snapshot} = snapshot) do
    %FrameSnapshot{
      snapshot
      | next_candidates: [],
        constraints: Enum.take(snapshot.constraints, 1)
    }
  end

  defp shape_by_type(%FrameSnapshot{} = snapshot), do: snapshot

  defp normalize_snapshot_type(type) when type in @snapshot_types, do: type
  defp normalize_snapshot_type(_), do: :action_snapshot

  defp extract_goal(runtime_state) do
    runtime_state
    |> read(:goal)
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp extract_policy(runtime_state) do
    case read(runtime_state, :policy) do
      %{} = policy -> policy
      _ -> nil
    end
  end

  defp extract_current_focus(runtime_state) do
    case read(runtime_state, :current_focus) do
      value when is_binary(value) -> truncate_text(value, @focus_max_chars)
      %{} = focus -> normalize_focus_map(focus)
      _ -> nil
    end
  end

  defp normalize_focus_map(focus) do
    text =
      focus
      |> read(:text)
      |> normalize_text()
      |> truncate_text(@focus_max_chars)

    refs =
      focus
      |> read(:refs, [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.take(@focus_refs_max)

    %{
      text: text,
      refs: refs
    }
  end

  defp extract_next_candidates(runtime_state) do
    runtime_state
    |> read(:next_candidates, [])
    |> List.wrap()
    |> Enum.map(&normalize_candidate/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@candidates_max)
  end

  defp normalize_candidate(%{} = candidate) do
    id = read(candidate, :id)
    title = read(candidate, :title)

    cond do
      is_binary(title) and title != "" -> %{id: id, title: title}
      true -> nil
    end
  end

  defp normalize_candidate(_), do: nil

  defp extract_constraints(runtime_state) do
    runtime_state
    |> read(:constraints, [])
    |> List.wrap()
    |> Enum.map(&normalize_constraint/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1.active == true))
    |> Enum.take(@active_constraints_max)
  end

  defp normalize_constraint(%{} = constraint) do
    text = read(constraint, :text)
    active = truthy?(read(constraint, :active, false))

    if is_binary(text) and text != "" do
      %{text: text, active: active}
    else
      nil
    end
  end

  defp normalize_constraint(_), do: nil

  defp extract_recommendations(runtime_state) do
    runtime_state
    |> read(:recommendations, [])
    |> List.wrap()
    |> Enum.map(&normalize_recommendation/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@recommendations_max)
  end

  defp normalize_recommendation(%{} = recommendation) do
    text =
      recommendation
      |> read(:text)
      |> normalize_text()
      |> truncate_text(@recommendation_text_max)

    priority = read(recommendation, :priority)
    source = read(recommendation, :source)

    if text != "" do
      %{
        text: text,
        priority: priority,
        source: source
      }
      |> drop_nil_values()
    else
      nil
    end
  end

  defp normalize_recommendation(value) when is_binary(value) do
    text = truncate_text(value, @recommendation_text_max)
    if text == "", do: nil, else: %{text: text}
  end

  defp normalize_recommendation(_), do: nil

  # 始终保留最小可追溯引用，避免 frame 与 runtime 状态脱节。
  defp extract_state_ref(runtime_state) do
    event_id = runtime_state |> extract_ref_ids(:event_ids) |> List.first()
    node_id = runtime_state |> extract_ref_ids(:node_ids) |> List.first()

    %{}
    |> maybe_put(:event_id, event_id)
    |> maybe_put(:node_id, node_id)
  end

  defp build_debug_info(_runtime_state, false), do: nil

  # debug 打开时回传完整引用集合，便于离线诊断。
  defp build_debug_info(runtime_state, true) do
    event_ids = extract_ref_ids(runtime_state, :event_ids)
    node_ids = extract_ref_ids(runtime_state, :node_ids)

    %{
      event_ids: event_ids,
      node_ids: node_ids
    }
  end

  defp extract_ref_ids(runtime_state, key) do
    runtime_state
    |> read(key, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(_), do: ""

  defp truncate_text(text, max_chars) when is_binary(text) do
    text
    |> String.trim()
    |> String.slice(0, max_chars)
  end

  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_), do: false

  defp drop_nil_values(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      if is_nil(value), do: acc, else: Map.put(acc, key, value)
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp read(data, key, default \\ nil)

  defp read(%{} = data, key, default) when is_atom(key) do
    Map.get(data, key, Map.get(data, Atom.to_string(key), default))
  end

  defp read(_data, _key, default), do: default
end
