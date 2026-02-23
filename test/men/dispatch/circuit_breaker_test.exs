defmodule Men.Dispatch.CircuitBreakerTest do
  use ExUnit.Case, async: true

  alias Men.Dispatch.CircuitBreaker

  test "连续失败达到阈值后开路" do
    breaker = CircuitBreaker.new(failure_threshold: 3, window_seconds: 30, cooldown_seconds: 60)

    breaker = CircuitBreaker.record_failure(breaker, 1_000)
    breaker = CircuitBreaker.record_failure(breaker, 2_000)
    breaker = CircuitBreaker.record_failure(breaker, 3_000)

    status = CircuitBreaker.status(breaker, 3_000)
    assert status.mode == :open

    assert {:deny, _} = CircuitBreaker.allow?(breaker, 3_500)
  end

  test "冷却后半开，仅允许一次探测" do
    breaker = CircuitBreaker.new(failure_threshold: 1, window_seconds: 30, cooldown_seconds: 10)
    breaker = CircuitBreaker.record_failure(breaker, 1_000)

    assert {:allow, half_open} = CircuitBreaker.allow?(breaker, 11_000)
    assert CircuitBreaker.status(half_open, 11_000).mode == :half_open

    assert {:deny, _} = CircuitBreaker.allow?(half_open, 11_001)
  end

  test "半开探测成功后恢复闭路" do
    breaker = CircuitBreaker.new(failure_threshold: 1, window_seconds: 30, cooldown_seconds: 10)
    breaker = CircuitBreaker.record_failure(breaker, 1_000)
    {:allow, half_open} = CircuitBreaker.allow?(breaker, 11_000)

    closed = CircuitBreaker.record_success(half_open, 11_100)
    assert CircuitBreaker.status(closed, 11_100).mode == :closed
    assert {:allow, _} = CircuitBreaker.allow?(closed, 11_101)
  end
end
