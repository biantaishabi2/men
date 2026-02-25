#!/usr/bin/env bash
set -euo pipefail

# Niuma 集成 gate：统一执行编译与测试。
export MIX_ENV="test"

# 仅在命令失败时打印尾部日志，避免 gate 截断后丢失真正报错。
run_with_log_tail() {
  local log_file
  local status

  log_file="$(mktemp)"
  if "$@" >"$log_file" 2>&1; then
    rm -f "$log_file"
    return 0
  fi

  status=$?
  echo "command failed: $*"
  echo "----- last 120 lines -----"
  tail -n 120 "$log_file"
  echo "--------------------------"
  rm -f "$log_file"
  return "$status"
}

# 锁定依赖解析范围与 lock 文件，避免 gate 受环境漂移影响。
# 网络瞬时抖动时做重试；重试前清理可能的半拉取状态，避免污染后续尝试。
deps_get_ok=0
max_attempts=3

for attempt in $(seq 1 "$max_attempts"); do
  if run_with_log_tail mix deps.get --only test --check-locked; then
    deps_get_ok=1
    break
  fi

  if [ "$attempt" -lt "$max_attempts" ]; then
    sleep_seconds=$((attempt * 3))
    echo "deps.get failed on attempt ${attempt}/${max_attempts}; cleaning deps and retrying in ${sleep_seconds}s..."
    rm -rf deps _build/test
    sleep "$sleep_seconds"
  fi
done

if [ "$deps_get_ok" -ne 1 ]; then
  echo "deps.get failed after retries"
  exit 1
fi

run_with_log_tail mix compile --warnings-as-errors
run_with_log_tail mix test
