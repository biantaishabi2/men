defmodule Men.RuntimeBridge.GongCLI do
  @moduledoc """
  基于 gong CLI 的 Runtime Bridge 实现。
  """

  @behaviour Men.RuntimeBridge.Bridge

  import Bitwise

  require Logger

  @counter_table :men_runtime_bridge_counter
  @default_timeout_ms 30_000
  @default_max_concurrency 10
  @default_backpressure_strategy :reject
  @default_outer_wait_buffer_ms 2_000
  @default_outer_shutdown_timeout_ms 5_000

  @impl true
  def start_turn(prompt, context) when is_binary(prompt) and is_map(context) do
    request_id = context_value(context, :request_id, "unknown_request")
    session_key = context_value(context, :session_key, "unknown_session")
    run_id = context_value(context, :run_id, generate_run_id())

    cfg = runtime_config()
    timeout_ms = Keyword.get(cfg, :timeout_ms, @default_timeout_ms)
    max_concurrency = Keyword.get(cfg, :max_concurrency, @default_max_concurrency)
    backpressure_strategy = Keyword.get(cfg, :backpressure_strategy, @default_backpressure_strategy)

    case acquire_slot(max_concurrency, backpressure_strategy) do
      :ok ->
        started_at = System.monotonic_time(:millisecond)

        try do
          run_with_timeout(prompt, request_id, session_key, run_id, cfg, timeout_ms, started_at)
        after
          release_slot()
        end

      {:error, :overloaded} ->
        duration_ms = 0
        error = overloaded_error(request_id, session_key, run_id, max_concurrency, duration_ms)

        log_event(request_id, session_key, run_id, duration_ms,
          exit_code: nil,
          timeout: false,
          cleanup_result: nil,
          result: :overloaded
        )

        {:error, error}
    end
  end

  def start_turn(prompt, context) when is_binary(prompt) and is_list(context) do
    start_turn(prompt, Map.new(context))
  end

  def start_turn(_prompt, _context) do
    raise ArgumentError, "start_turn/2 expects prompt binary and context map/keyword"
  end

  defp run_with_timeout(prompt, request_id, session_key, run_id, cfg, timeout_ms, started_at) do
    case run_cli_command(prompt, request_id, session_key, run_id, cfg, timeout_ms) do
      {:ok, text, exit_code, cleanup_result} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        log_event(request_id, session_key, run_id, duration_ms,
          exit_code: exit_code,
          timeout: false,
          cleanup_result: cleanup_result,
          result: :ok
        )

        {:ok,
         %{
           text: text,
           meta: %{
             run_id: run_id,
             request_id: request_id,
             session_key: session_key,
             duration_ms: duration_ms,
             exit_code: exit_code
           }
         }}

      {:error, output, exit_code, cleanup_result} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        log_event(request_id, session_key, run_id, duration_ms,
          exit_code: exit_code,
          timeout: false,
          cleanup_result: cleanup_result,
          result: :failed
        )

        {:error,
         %{
           type: :failed,
           code: "CLI_EXIT_#{exit_code}",
           message: "gong cli exited with non-zero status #{exit_code}",
           run_id: run_id,
           request_id: request_id,
           session_key: session_key,
           details: %{
             output: output,
             exit_code: exit_code,
             duration_ms: duration_ms
           }
         }}

      {:timeout, output, cleanup_result} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        log_event(request_id, session_key, run_id, duration_ms,
          exit_code: nil,
          timeout: true,
          cleanup_result: cleanup_result,
          result: :timeout
        )

        {:error,
         %{
           type: :timeout,
           code: "CLI_TIMEOUT",
           message: "gong cli timed out after #{timeout_ms}ms",
           run_id: run_id,
           request_id: request_id,
           session_key: session_key,
           details: %{
             output: output,
             timeout_ms: timeout_ms,
             duration_ms: duration_ms,
             cleanup_result: inspect(cleanup_result)
           }
         }}
    end
  end

  defp run_cli_command(prompt, request_id, session_key, run_id, cfg, timeout_ms) do
    command = Keyword.get(cfg, :command, "gong")
    args = build_args(cfg, prompt, request_id, session_key, run_id)

    case resolve_command_path(command) do
      {:ok, command_path} ->
        run_port_command_with_task_timeout(command_path, args, timeout_ms, cfg)

      :error ->
        {:error, "command not found: #{command}", 127, :not_started}
    end
  end

  defp run_port_command_with_task_timeout(command_path, args, timeout_ms, cfg) do
    task =
      Task.async(fn ->
        run_port_command(command_path, args, timeout_ms)
      end)

    wait_buffer_ms =
      normalize_non_negative_integer(
        Keyword.get(cfg, :outer_wait_buffer_ms, @default_outer_wait_buffer_ms),
        @default_outer_wait_buffer_ms
      )

    shutdown_timeout_ms =
      normalize_non_negative_integer(
        Keyword.get(cfg, :outer_shutdown_timeout_ms, @default_outer_shutdown_timeout_ms),
        @default_outer_shutdown_timeout_ms
      )

    wait_ms = timeout_ms + wait_buffer_ms

    case Task.yield(task, wait_ms) do
      {:ok, result} ->
        result

      nil ->
        shutdown_result = Task.shutdown(task, shutdown_timeout_ms)
        final_shutdown_result = if is_nil(shutdown_result), do: Task.shutdown(task, :brutal_kill), else: shutdown_result
        {:timeout, "", %{task_shutdown: inspect(final_shutdown_result), source: :outer_guard}}
    end
  end

  defp run_port_command(command_path, args, timeout_ms) do
    try do
      port =
        Port.open({:spawn_executable, command_path}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          :hide,
          args: args
        ])

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
      await_port_result(port, os_pid, deadline_ms, "")
    catch
      :error, reason ->
        {:error, "failed to start command: #{inspect(reason)}", 127, :not_started}

      :exit, reason ->
        {:error, "failed to start command: #{inspect(reason)}", 127, :not_started}
    end
  end

  # 统一在一个 receive 循环里处理输出、退出码和超时清理，避免遗留子进程。
  defp await_port_result(port, os_pid, deadline_ms, output) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        await_port_result(port, os_pid, deadline_ms, output <> chunk)

      {^port, {:exit_status, 0}} ->
        {:ok, output, 0, :not_needed}

      {^port, {:exit_status, exit_code}} ->
        {:error, output, exit_code, :not_needed}
    after
      remaining_ms ->
        cleanup_result = cleanup_timed_out_port(port, os_pid)
        {:timeout, output, cleanup_result}
    end
  end

  defp cleanup_timed_out_port(port, os_pid) do
    port_close_result =
      try do
        Port.close(port)
        :closed
      catch
        :exit, _ -> :already_closed
      end

    kill_children_result = terminate_child_processes(os_pid, "-TERM")
    kill_term_result = terminate_pid(os_pid, "-TERM")
    Process.sleep(30)
    kill_force_result = terminate_pid(os_pid, "-KILL")

    %{
      port_close: port_close_result,
      kill_children: kill_children_result,
      kill_term: kill_term_result,
      kill_kill: kill_force_result
    }
  end

  defp terminate_child_processes(nil, _signal), do: :no_pid

  defp terminate_child_processes(os_pid, signal) do
    case System.find_executable("pkill") do
      nil ->
        :pkill_not_found

      _ ->
        {_, code} =
          System.cmd("pkill", [signal, "-P", Integer.to_string(os_pid)],
            stderr_to_stdout: true
          )

        {:pkill, code}
    end
  end

  defp terminate_pid(nil, _signal), do: :no_pid

  defp terminate_pid(os_pid, signal) do
    case System.find_executable("kill") do
      nil ->
        :kill_not_found

      _ ->
        {_, code} =
          System.cmd("kill", [signal, Integer.to_string(os_pid)], stderr_to_stdout: true)

        {:kill, code}
    end
  end

  defp resolve_command_path(command) do
    cond do
      String.contains?(command, "/") and executable_file?(command) ->
        {:ok, command}

      true ->
        case System.find_executable(command) do
          nil -> :error
          path -> {:ok, path}
        end
    end
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> (mode &&& 0o111) != 0
      _ -> false
    end
  end

  defp build_args(cfg, prompt, request_id, session_key, run_id) do
    base_args = Keyword.get(cfg, :command_args, [])

    base_args
    |> maybe_put_arg(Keyword.get(cfg, :prompt_arg, "--prompt"), prompt)
    |> maybe_put_arg(Keyword.get(cfg, :request_id_arg, "--request-id"), request_id)
    |> maybe_put_arg(Keyword.get(cfg, :session_key_arg, "--session-key"), session_key)
    |> maybe_put_arg(Keyword.get(cfg, :run_id_arg, "--run-id"), run_id)
  end

  defp maybe_put_arg(args, nil, _value), do: args
  defp maybe_put_arg(args, _arg_name, nil), do: args
  defp maybe_put_arg(args, arg_name, value), do: args ++ [arg_name, value]

  defp acquire_slot(max_concurrency, :reject) do
    ensure_counter_table!()
    current = :ets.update_counter(@counter_table, :counter, {2, 1}, {:counter, 0})

    if current <= max_concurrency do
      :ok
    else
      _ = :ets.update_counter(@counter_table, :counter, {2, -1}, {:counter, 0})
      {:error, :overloaded}
    end
  end

  defp acquire_slot(_max_concurrency, strategy) do
    raise ArgumentError, "unsupported backpressure strategy: #{inspect(strategy)}"
  end

  defp release_slot do
    ensure_counter_table!()
    current = :ets.update_counter(@counter_table, :counter, {2, -1}, {:counter, 0})

    if current < 0 do
      :ets.insert(@counter_table, {:counter, 0})
    end

    :ok
  end

  defp ensure_counter_table! do
    case :ets.info(@counter_table) do
      :undefined ->
        heir_pid = Process.whereis(:init)
        table_opts = [:named_table, :public, :set, read_concurrency: true]

        table_opts =
          if is_pid(heir_pid) do
            table_opts ++ [{:heir, heir_pid, :transfer}]
          else
            table_opts
          end

        try do
          :ets.new(@counter_table, table_opts)
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp overloaded_error(request_id, session_key, run_id, max_concurrency, duration_ms) do
    %{
      type: :overloaded,
      code: "CLI_OVERLOADED",
      message: "runtime bridge is overloaded with max_concurrency=#{max_concurrency}",
      run_id: run_id,
      request_id: request_id,
      session_key: session_key,
      details: %{
        max_concurrency: max_concurrency,
        duration_ms: duration_ms
      }
    }
  end

  defp context_value(context, key, default) do
    context
    |> Map.get(key, Map.get(context, Atom.to_string(key), default))
    |> normalize_context_value(default)
  end

  defp normalize_context_value(nil, default), do: default
  defp normalize_context_value("", default), do: default
  defp normalize_context_value(value, _default) when is_binary(value), do: value
  defp normalize_context_value(value, _default), do: to_string(value)

  defp generate_run_id do
    "run_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 16)
  end

  defp normalize_non_negative_integer(value, default)
       when is_integer(value) and value >= 0,
       do: value

  defp normalize_non_negative_integer(_value, default), do: default

  defp runtime_config do
    Application.get_env(:men, :runtime_bridge, [])
  end

  defp log_event(request_id, session_key, run_id, duration_ms, opts) do
    Logger.info("runtime_bridge.gong_cli.start_turn",
      request_id: request_id,
      session_key: session_key,
      run_id: run_id,
      duration_ms: duration_ms,
      exit_code: Keyword.get(opts, :exit_code),
      timeout: Keyword.get(opts, :timeout),
      cleanup_result: inspect(Keyword.get(opts, :cleanup_result)),
      result: Keyword.get(opts, :result)
    )
  end
end
