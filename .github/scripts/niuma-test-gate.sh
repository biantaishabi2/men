#!/usr/bin/env bash
set -euo pipefail

# Niuma 集成 gate：统一执行编译与测试。
export MIX_ENV="test"

# 锁定依赖解析范围与 lock 文件，避免 gate 受环境漂移影响。
mix deps.get --only test --check-locked
mix compile --warnings-as-errors
mix test
