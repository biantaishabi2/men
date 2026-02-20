#!/bin/bash
set -euo pipefail

# Niuma 集成 gate：统一执行编译与测试。
export MIX_ENV="${MIX_ENV:-test}"

mix deps.get
mix compile --warnings-as-errors
mix test
