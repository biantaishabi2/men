defmodule Men.Gateway.TaskScheduler do
  @moduledoc """
  Gateway 调度扫描器：负责周期扫描到期任务，并投递到 TaskDispatcher。
  """

  use GenServer

  require Logger

  alias Men.Gateway.TaskDispatcher

  @default_tick_interval_ms 1_000
  @default_min_catchup_window_ms :timer.minutes(5)
  @daily_cron "0 0 * * *"

  @type schedule_type :: :at | :cron | :daily

  @type state :: %{
          dispatcher: GenServer.server(),
          schedule_source: (-> list()),
          tick_interval_ms: pos_integer(),
          catchup_window_ms: pos_integer(),
          clock: (-> DateTime.t()),
          last_tick_at: DateTime.t() | nil,
          auto_tick?: boolean(),
          timer_ref: reference() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec trigger_tick(GenServer.server()) :: {:ok, non_neg_integer()}
  def trigger_tick(server \\ __MODULE__) do
    GenServer.call(server, :trigger_tick)
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:men, __MODULE__, [])
    tick_interval_ms = build_tick_interval(opts, config)

    state = %{
      dispatcher:
        Keyword.get(opts, :dispatcher, Keyword.get(config, :dispatcher, TaskDispatcher)),
      schedule_source: schedule_source(opts, config),
      tick_interval_ms: tick_interval_ms,
      catchup_window_ms: build_catchup_window(opts, config, tick_interval_ms),
      clock: Keyword.get(opts, :clock, Keyword.get(config, :clock, &DateTime.utc_now/0)),
      last_tick_at: nil,
      auto_tick?: Keyword.get(opts, :auto_tick?, Keyword.get(config, :auto_tick?, true)),
      timer_ref: nil
    }

    if state.auto_tick? do
      send(self(), :tick)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:trigger_tick, _from, state) do
    {dispatch_count, next_state} = run_tick(state)
    {:reply, {:ok, dispatch_count}, next_state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_dispatch_count, next_state} = run_tick(state)
    {:noreply, schedule_next_tick(next_state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp run_tick(state) do
    now = now_utc(state.clock)

    window_start =
      case state.last_tick_at do
        %DateTime{} = last_tick_at -> last_tick_at
        nil -> DateTime.add(now, -state.catchup_window_ms, :millisecond)
      end

    {dispatch_count, invalid_count} = dispatch_due_schedules(state, window_start, now)

    emit_telemetry(:tick, %{
      dispatch_count: dispatch_count,
      invalid_count: invalid_count,
      catchup_window_ms: state.catchup_window_ms
    })

    {dispatch_count, %{state | last_tick_at: now}}
  end

  defp dispatch_due_schedules(state, window_start, now) do
    state.schedule_source.()
    |> List.wrap()
    |> Enum.reduce({0, 0}, fn schedule, {dispatch_count, invalid_count} ->
      case normalize_schedule(schedule) do
        {:ok, normalized_schedule} ->
          fire_times = due_fire_times(normalized_schedule, window_start, now)

          Enum.each(fire_times, fn fire_time ->
            TaskDispatcher.dispatch(state.dispatcher, %{
              schedule_id: normalized_schedule.schedule_id,
              schedule_type: normalized_schedule.schedule_type,
              fire_time: fire_time,
              metadata: normalized_schedule.metadata
            })
          end)

          {dispatch_count + length(fire_times), invalid_count}

        {:error, reason} ->
          Logger.warning("task scheduler ignored invalid schedule: #{inspect(reason)}")
          {dispatch_count, invalid_count + 1}
      end
    end)
  rescue
    error ->
      Logger.error("task scheduler scan failed: #{Exception.message(error)}")
      {0, 1}
  end

  @spec normalize_schedule(map()) :: {:ok, map()} | {:error, term()}
  def normalize_schedule(schedule) when is_map(schedule) do
    with {:ok, schedule_id} <- normalize_schedule_id(schedule),
         {:ok, schedule_type, cron_expr} <- normalize_schedule_type(schedule),
         {:ok, next_run_at} <- normalize_next_run_at(schedule),
         {:ok, parsed_cron} <- parse_schedule_cron(schedule_type, cron_expr) do
      {:ok,
       %{
         schedule_id: schedule_id,
         schedule_type: schedule_type,
         next_run_at: next_run_at,
         cron_expr: cron_expr,
         parsed_cron: parsed_cron,
         metadata: normalize_metadata(schedule)
       }}
    end
  end

  def normalize_schedule(_), do: {:error, :invalid_schedule}

  @spec due_fire_times(map(), DateTime.t(), DateTime.t()) :: [DateTime.t()]
  def due_fire_times(schedule, window_start, now)
      when is_map(schedule) and is_struct(window_start, DateTime) and is_struct(now, DateTime) do
    if DateTime.compare(schedule.next_run_at, now) == :gt do
      []
    else
      case schedule.schedule_type do
        :at ->
          if in_window?(schedule.next_run_at, window_start, now),
            do: [schedule.next_run_at],
            else: []

        :cron ->
          cron_due_fire_times(schedule, window_start, now)
      end
    end
  end

  defp cron_due_fire_times(schedule, window_start, now) do
    start_at = max_datetime(schedule.next_run_at, window_start)
    candidate = ceil_to_minute(start_at)

    do_collect_cron_fire_times(
      candidate,
      now,
      schedule.next_run_at,
      window_start,
      schedule.parsed_cron,
      []
    )
  end

  defp do_collect_cron_fire_times(candidate, now, next_run_at, window_start, parsed_cron, acc) do
    if DateTime.compare(candidate, now) == :gt do
      Enum.reverse(acc)
    else
      matched? =
        DateTime.compare(candidate, next_run_at) != :lt and
          DateTime.compare(candidate, window_start) == :gt and
          cron_match?(candidate, parsed_cron)

      next_acc = if matched?, do: [candidate | acc], else: acc
      next_candidate = DateTime.add(candidate, 60, :second)

      do_collect_cron_fire_times(
        next_candidate,
        now,
        next_run_at,
        window_start,
        parsed_cron,
        next_acc
      )
    end
  end

  defp parse_schedule_cron(:at, _cron_expr), do: {:ok, nil}

  defp parse_schedule_cron(:cron, cron_expr) when is_binary(cron_expr) do
    parse_cron_expression(cron_expr)
  end

  defp parse_schedule_cron(:cron, _cron_expr), do: {:error, :invalid_cron_expression}

  defp normalize_schedule_id(schedule) do
    case fetch_value(schedule, :schedule_id) do
      schedule_id when is_binary(schedule_id) and schedule_id != "" -> {:ok, schedule_id}
      _ -> {:error, :invalid_schedule_id}
    end
  end

  defp normalize_schedule_type(schedule) do
    case fetch_value(schedule, :schedule_type) do
      type when type in [:at, "at"] -> {:ok, :at, nil}
      type when type in [:cron, "cron"] -> {:ok, :cron, fetch_cron_expr(schedule)}
      type when type in [:daily, "daily"] -> {:ok, :cron, @daily_cron}
      _ -> {:error, :invalid_schedule_type}
    end
  end

  defp normalize_next_run_at(schedule) do
    value = fetch_value(schedule, :next_run_at) || fetch_value(schedule, :scheduled_at)

    case value do
      %DateTime{} = datetime ->
        {:ok, DateTime.shift_zone!(datetime, "Etc/UTC")}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, DateTime.shift_zone!(datetime, "Etc/UTC")}
          _ -> {:error, :invalid_next_run_at}
        end

      value when is_integer(value) ->
        {:ok, DateTime.from_unix!(value, :millisecond)}

      _ ->
        {:error, :invalid_next_run_at}
    end
  end

  defp fetch_cron_expr(schedule) do
    fetch_value(schedule, :cron) || fetch_value(schedule, :cron_expr) ||
      fetch_value(schedule, :expression)
  end

  defp parse_cron_expression(expression) when is_binary(expression) do
    parts = String.split(expression, ~r/\s+/, trim: true)

    with [minute, hour, day_of_month, month, day_of_week] <- parts,
         {:ok, minute_field} <- parse_cron_field(minute, 0, 59),
         {:ok, hour_field} <- parse_cron_field(hour, 0, 23),
         {:ok, day_of_month_field} <- parse_cron_field(day_of_month, 1, 31),
         {:ok, month_field} <- parse_cron_field(month, 1, 12),
         {:ok, day_of_week_field} <- parse_day_of_week_field(day_of_week) do
      {:ok,
       %{
         minute: minute_field,
         hour: hour_field,
         day_of_month: day_of_month_field,
         month: month_field,
         day_of_week: day_of_week_field
       }}
    else
      _ -> {:error, :invalid_cron_expression}
    end
  end

  defp parse_cron_expression(_), do: {:error, :invalid_cron_expression}

  defp parse_day_of_week_field("*"), do: {:ok, :any}

  defp parse_day_of_week_field(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce_while(MapSet.new(), fn token, acc ->
      case Integer.parse(token) do
        {int_value, ""} when int_value in 0..7 ->
          normalized = if int_value == 7, do: 0, else: int_value
          {:cont, MapSet.put(acc, normalized)}

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, :invalid_cron_expression}
      set when map_size(set) > 0 -> {:ok, set}
      _ -> {:error, :invalid_cron_expression}
    end
  end

  defp parse_day_of_week_field(_), do: {:error, :invalid_cron_expression}

  defp parse_cron_field("*", _min, _max), do: {:ok, :any}

  defp parse_cron_field(value, min, max) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce_while(MapSet.new(), fn token, acc ->
      case Integer.parse(token) do
        {int_value, ""} when int_value >= min and int_value <= max ->
          {:cont, MapSet.put(acc, int_value)}

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, :invalid_cron_expression}
      set when map_size(set) > 0 -> {:ok, set}
      _ -> {:error, :invalid_cron_expression}
    end
  end

  defp parse_cron_field(_value, _min, _max), do: {:error, :invalid_cron_expression}

  defp cron_match?(datetime, parsed_cron) do
    matches_field?(parsed_cron.minute, datetime.minute) and
      matches_field?(parsed_cron.hour, datetime.hour) and
      matches_field?(parsed_cron.day_of_month, datetime.day) and
      matches_field?(parsed_cron.month, datetime.month) and
      matches_field?(parsed_cron.day_of_week, day_of_week(datetime))
  end

  defp matches_field?(:any, _value), do: true
  defp matches_field?(%MapSet{} = set, value), do: MapSet.member?(set, value)

  defp day_of_week(datetime) do
    case Date.day_of_week(DateTime.to_date(datetime)) do
      7 -> 0
      value -> value
    end
  end

  defp ceil_to_minute(datetime) do
    seconds = datetime.second
    microsecond = elem(datetime.microsecond, 0)

    floored = %{datetime | second: 0, microsecond: {0, 0}}

    if seconds == 0 and microsecond == 0 do
      floored
    else
      DateTime.add(floored, 60, :second)
    end
  end

  defp in_window?(datetime, window_start, now) do
    DateTime.compare(datetime, window_start) == :gt and
      DateTime.compare(datetime, now) in [:lt, :eq]
  end

  defp max_datetime(left, right) do
    case DateTime.compare(left, right) do
      :lt -> right
      _ -> left
    end
  end

  defp normalize_metadata(schedule) do
    case fetch_value(schedule, :metadata) do
      %{} = metadata -> metadata
      _ -> %{}
    end
  end

  defp fetch_value(schedule, key),
    do: Map.get(schedule, key) || Map.get(schedule, Atom.to_string(key))

  defp build_tick_interval(opts, config) do
    opts
    |> Keyword.get(
      :tick_interval_ms,
      Keyword.get(config, :tick_interval_ms, @default_tick_interval_ms)
    )
    |> normalize_positive_integer(@default_tick_interval_ms)
  end

  defp build_catchup_window(opts, config, tick_interval_ms) do
    configured_window =
      opts
      |> Keyword.get(:catchup_window_ms, Keyword.get(config, :catchup_window_ms))

    computed_window = max(@default_min_catchup_window_ms, tick_interval_ms * 2)

    case configured_window do
      value when is_integer(value) and value > 0 -> max(value, computed_window)
      _ -> computed_window
    end
  end

  defp normalize_positive_integer(value, _fallback)
       when is_integer(value) and value > 0,
       do: value

  defp normalize_positive_integer(_value, fallback), do: fallback

  defp schedule_source(opts, config) do
    source =
      Keyword.get(opts, :schedule_source, Keyword.get(config, :schedule_source, fn -> [] end))

    normalize_schedule_source(source)
  end

  defp normalize_schedule_source(source) when is_function(source, 0), do: source

  defp normalize_schedule_source({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    fn -> apply(module, function, args) end
  end

  defp normalize_schedule_source(module) when is_atom(module) do
    cond do
      function_exported?(module, :list_schedules, 0) -> fn -> module.list_schedules() end
      true -> fn -> [] end
    end
  end

  defp normalize_schedule_source(source) when is_list(source), do: fn -> source end
  defp normalize_schedule_source(_), do: fn -> [] end

  defp schedule_next_tick(state) do
    if state.auto_tick? do
      if is_reference(state.timer_ref), do: Process.cancel_timer(state.timer_ref)
      timer_ref = Process.send_after(self(), :tick, state.tick_interval_ms)
      %{state | timer_ref: timer_ref}
    else
      state
    end
  end

  defp now_utc(clock) do
    clock.()
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute([:men, :gateway, :task_scheduler, event], %{count: 1}, metadata)
  rescue
    _ -> :ok
  end
end
