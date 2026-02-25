#!/usr/bin/env bash
set -euo pipefail

# Niuma 集成 gate：统一执行编译与测试。
export MIX_ENV="test"

# 锁定依赖解析范围与 lock 文件，避免 gate 受环境漂移影响。
# 网络瞬时抖动时做一次轻量重试，避免依赖下载偶发失败直接打断 gate。
deps_get_ok=0
for attempt in 1 2; do
  if mix deps.get --only test --check-locked; then
    deps_get_ok=1
    break
  fi

  if [ "$attempt" -lt 2 ]; then
    echo "deps.get failed on attempt ${attempt}, retrying in 3s..."
    sleep 3
  fi
done

if [ "$deps_get_ok" -ne 1 ]; then
  echo "deps.get failed after retries"
  exit 1
fi

mix compile --warnings-as-errors
mix test
