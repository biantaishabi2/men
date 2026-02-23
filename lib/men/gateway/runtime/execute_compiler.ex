defmodule Men.Gateway.Runtime.ExecuteCompiler do
  @moduledoc """
  Execute 图 DAG 编译器。
  """

  @spec compile(map()) ::
          {:ok, map()} | {:error, {:missing_nodes, map()} | {:cycle_detected, map()}}
  def compile(input) when is_map(input) do
    with {:ok, normalized} <- normalize_input(input),
         :ok <- validate_missing_nodes(normalized),
         :ok <- detect_cycle(normalized) do
      {:ok, build_execution_plan(normalized)}
    end
  end

  defp normalize_input(input) do
    tasks =
      input
      |> Map.get(:tasks, [])
      |> List.wrap()
      |> Enum.map(&normalize_task/1)

    edges_from_tasks =
      Enum.flat_map(tasks, fn task ->
        Enum.map(task.blocked_by, fn blocker -> %{from: blocker, to: task.task_id} end)
      end)

    extra_edges =
      input
      |> Map.get(:edges, [])
      |> List.wrap()
      |> Enum.map(&normalize_edge/1)

    all_edges =
      (edges_from_tasks ++ extra_edges)
      |> Enum.uniq_by(fn edge -> {edge.from, edge.to} end)
      |> Enum.sort_by(fn edge -> {edge.from, edge.to} end)

    task_ids = tasks |> Enum.map(& &1.task_id) |> Enum.uniq() |> Enum.sort()

    blocked_by =
      Enum.reduce(task_ids, %{}, fn task_id, acc ->
        blockers =
          all_edges
          |> Enum.filter(&(&1.to == task_id))
          |> Enum.map(& &1.from)
          |> Enum.uniq()
          |> Enum.sort()

        Map.put(acc, task_id, blockers)
      end)

    {:ok, %{task_ids: task_ids, blocked_by: blocked_by, edges: all_edges}}
  end

  defp normalize_task(task) do
    task_id = to_string(Map.get(task, :task_id) || Map.get(task, "task_id") || "")

    blocked_by =
      task
      |> Map.get(:blocked_by, Map.get(task, "blocked_by", []))
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{task_id: task_id, blocked_by: blocked_by}
  end

  defp normalize_edge(edge) do
    %{
      from: to_string(Map.get(edge, :from) || Map.get(edge, "from") || ""),
      to: to_string(Map.get(edge, :to) || Map.get(edge, "to") || "")
    }
  end

  defp validate_missing_nodes(%{task_ids: task_ids, edges: edges}) do
    task_set = MapSet.new(task_ids)

    missing_nodes =
      edges
      |> Enum.flat_map(fn edge -> [edge.from, edge.to] end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(task_set, &1))
      |> Enum.sort()

    if missing_nodes == [] do
      :ok
    else
      related_edges =
        Enum.filter(edges, fn edge -> edge.from in missing_nodes or edge.to in missing_nodes end)

      {:error,
       {:missing_nodes,
        %{
          missing_node_ids: missing_nodes,
          edges: Enum.map(related_edges, fn edge -> %{from: edge.from, to: edge.to} end)
        }}}
    end
  end

  defp detect_cycle(%{task_ids: task_ids, blocked_by: blocked_by, edges: edges}) do
    adjacency = build_adjacency(task_ids, edges)

    case find_first_cycle(task_ids, adjacency) do
      nil ->
        :ok

      cycle_nodes ->
        cycle_edges =
          cycle_nodes
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [from, to] -> %{from: from, to: to} end)

        {:error,
         {:cycle_detected,
          %{cycle_nodes: cycle_nodes, edges: cycle_edges, blocked_by: blocked_by}}}
    end
  end

  defp build_adjacency(task_ids, edges) do
    base = Enum.into(task_ids, %{}, fn task_id -> {task_id, []} end)

    Enum.reduce(edges, base, fn edge, acc ->
      Map.update!(acc, edge.from, fn neighbors ->
        [edge.to | neighbors] |> Enum.uniq() |> Enum.sort()
      end)
    end)
  end

  defp find_first_cycle(task_ids, adjacency) do
    Enum.reduce_while(task_ids, %{visited: MapSet.new(), cycle: nil}, fn node, acc ->
      if MapSet.member?(acc.visited, node) do
        {:cont, acc}
      else
        case dfs_cycle(node, adjacency, acc.visited, MapSet.new(), []) do
          {:cycle, cycle_nodes, visited} -> {:halt, %{acc | cycle: cycle_nodes, visited: visited}}
          {:ok, visited} -> {:cont, %{acc | visited: visited}}
        end
      end
    end)
    |> Map.get(:cycle)
  end

  defp dfs_cycle(node, adjacency, visited, stack_set, stack_path) do
    visited = MapSet.put(visited, node)
    stack_set = MapSet.put(stack_set, node)
    stack_path = [node | stack_path]

    neighbors = Map.get(adjacency, node, [])

    Enum.reduce_while(neighbors, {:ok, visited, stack_set, stack_path}, fn neighbor,
                                                                           {:ok, v_acc, s_acc,
                                                                            p_acc} ->
      cond do
        MapSet.member?(s_acc, neighbor) ->
          cycle_nodes = extract_cycle_nodes(neighbor, p_acc)
          {:halt, {:cycle, cycle_nodes, v_acc}}

        MapSet.member?(v_acc, neighbor) ->
          {:cont, {:ok, v_acc, s_acc, p_acc}}

        true ->
          case dfs_cycle(neighbor, adjacency, v_acc, s_acc, p_acc) do
            {:cycle, cycle_nodes, visited_after} -> {:halt, {:cycle, cycle_nodes, visited_after}}
            {:ok, visited_after} -> {:cont, {:ok, visited_after, s_acc, p_acc}}
          end
      end
    end)
    |> case do
      {:cycle, cycle_nodes, visited_after} -> {:cycle, cycle_nodes, visited_after}
      {:ok, visited_after, _, _} -> {:ok, visited_after}
    end
  end

  # 返回 DFS 首个回边对应的闭环链路，结尾重复起点。
  defp extract_cycle_nodes(target, stack_path) do
    path = Enum.reverse(stack_path)
    idx = Enum.find_index(path, &(&1 == target)) || 0
    segment = Enum.drop(path, idx)
    segment ++ [target]
  end

  defp build_execution_plan(%{task_ids: task_ids, blocked_by: blocked_by, edges: edges}) do
    indegree = Enum.into(task_ids, %{}, fn task_id -> {task_id, 0} end)

    indegree =
      Enum.reduce(edges, indegree, fn edge, acc ->
        Map.update!(acc, edge.to, &(&1 + 1))
      end)

    adjacency = build_adjacency(task_ids, edges)

    {layers, _indegree, _remaining} = topo_layers(task_ids, indegree, adjacency, [])

    %{
      layers: layers,
      blocked_by: blocked_by,
      edges: Enum.map(edges, fn edge -> %{from: edge.from, to: edge.to} end)
    }
  end

  defp topo_layers(task_ids, indegree, adjacency, acc_layers) do
    current_layer =
      task_ids
      |> Enum.filter(&(Map.get(indegree, &1, 0) == 0))
      |> Enum.sort()

    if current_layer == [] do
      {Enum.reverse(acc_layers), indegree, task_ids}
    else
      remaining = task_ids -- current_layer

      next_indegree =
        Enum.reduce(current_layer, indegree, fn node, acc ->
          Enum.reduce(Map.get(adjacency, node, []), acc, fn dependent, acc2 ->
            Map.update!(acc2, dependent, &(&1 - 1))
          end)
        end)

      topo_layers(remaining, next_indegree, adjacency, [current_layer | acc_layers])
    end
  end
end
