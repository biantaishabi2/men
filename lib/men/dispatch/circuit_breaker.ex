defmodule Men.Dispatch.CircuitBreaker do
  @moduledoc """
  轻量熔断状态机（进程内状态）。

  - 连续失败窗口达到阈值后开路
  - 冷却期结束进入半开，仅允许一次探测
  - 探测成功则闭路恢复，失败则重新开路
  """

  @type mode :: :closed | :open | :half_open

  @type t :: %{
          mode: mode(),
          failures: [non_neg_integer()],
          open_until_ms: non_neg_integer(),
          probe_in_flight: boolean(),
          failure_threshold: pos_integer(),
          window_ms: pos_integer(),
          cooldown_ms: pos_integer()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    failure_threshold = Keyword.get(opts, :failure_threshold, 5)
    window_seconds = Keyword.get(opts, :window_seconds, 30)
    cooldown_seconds = Keyword.get(opts, :cooldown_seconds, 60)

    %{
      mode: :closed,
      failures: [],
      open_until_ms: 0,
      probe_in_flight: false,
      failure_threshold: max(failure_threshold, 1),
      window_ms: max(window_seconds, 1) * 1_000,
      cooldown_ms: max(cooldown_seconds, 1) * 1_000
    }
  end

  @spec allow?(t(), non_neg_integer()) :: {:allow | :deny, t()}
  def allow?(state, now_ms \\ now_ms()) do
    case state.mode do
      :closed ->
        {:allow, state}

      :open ->
        if now_ms >= state.open_until_ms do
          next = %{state | mode: :half_open, probe_in_flight: true}
          {:allow, next}
        else
          {:deny, state}
        end

      :half_open ->
        if state.probe_in_flight do
          {:deny, state}
        else
          {:allow, %{state | probe_in_flight: true}}
        end
    end
  end

  @spec record_success(t(), non_neg_integer()) :: t()
  def record_success(state, _now_ms \\ now_ms()) do
    %{state | mode: :closed, failures: [], probe_in_flight: false, open_until_ms: 0}
  end

  @spec record_failure(t(), non_neg_integer()) :: t()
  def record_failure(state, now_ms \\ now_ms()) do
    case state.mode do
      :half_open ->
        open(state, now_ms)

      _ ->
        failures =
          state.failures
          |> keep_recent(now_ms, state.window_ms)
          |> Kernel.++([now_ms])

        if length(failures) >= state.failure_threshold do
          %{open(state, now_ms) | failures: failures}
        else
          %{state | failures: failures, probe_in_flight: false}
        end
    end
  end

  @spec status(t(), non_neg_integer()) :: map()
  def status(state, now_ms \\ now_ms()) do
    mode =
      if state.mode == :open and now_ms >= state.open_until_ms do
        :half_open
      else
        state.mode
      end

    %{
      mode: mode,
      failure_count: length(keep_recent(state.failures, now_ms, state.window_ms)),
      failure_threshold: state.failure_threshold,
      window_ms: state.window_ms,
      cooldown_ms: state.cooldown_ms,
      open_until_ms: state.open_until_ms
    }
  end

  defp open(state, now_ms) do
    %{
      state
      | mode: :open,
        open_until_ms: now_ms + state.cooldown_ms,
        probe_in_flight: false
    }
  end

  defp keep_recent(failures, now_ms, window_ms) do
    min_ms = now_ms - window_ms
    Enum.filter(failures, &(&1 >= min_ms))
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
