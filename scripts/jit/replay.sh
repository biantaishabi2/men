#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  scripts/jit/replay.sh --input <telemetry.jsonl> [--trace-id <id>] [--session-id <id>]

说明:
  - 输入文件为 JSON Lines，每行一个 telemetry 事件。
  - 支持按 trace_id 和/或 session_id 过滤。
  - 输出决策链关键字段，便于复现 JIT 编排路径。
USAGE
}

INPUT=""
TRACE_ID=""
SESSION_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      if [[ -z "${2-}" ]]; then
        echo "参数 --input 缺少值" >&2
        usage
        exit 1
      fi
      INPUT="$2"
      shift 2
      ;;
    --trace-id)
      if [[ -z "${2-}" ]]; then
        echo "参数 --trace-id 缺少值" >&2
        usage
        exit 1
      fi
      TRACE_ID="$2"
      shift 2
      ;;
    --session-id)
      if [[ -z "${2-}" ]]; then
        echo "参数 --session-id 缺少值" >&2
        usage
        exit 1
      fi
      SESSION_ID="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$INPUT" ]]; then
  echo "缺少 --input 参数" >&2
  usage
  exit 1
fi

if [[ ! -f "$INPUT" ]]; then
  echo "输入文件不存在: $INPUT" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "需要 jq 命令，请先安装 jq" >&2
  exit 1
fi

jq -r \
  --arg trace_id "$TRACE_ID" \
  --arg session_id "$SESSION_ID" \
  '
  select((($trace_id == "") or (.trace_id == $trace_id)) and (($session_id == "") or (.session_id == $session_id)))
  | [
      (.ts // .timestamp // "-"),
      (.event // "-"),
      (.trace_id // "-"),
      (.session_id // "-"),
      (.flag_state // "-"),
      (.advisor_decision // "-"),
      (.snapshot_action // "-"),
      (.rollback_reason // "-")
    ]
  | @tsv
  ' "$INPUT" \
| awk 'BEGIN {
    printf "%-24s %-22s %-20s %-20s %-12s %-18s %-16s %-18s\n", "time", "event", "trace_id", "session_id", "flag", "advisor", "snapshot", "rollback"
    printf "%s\n", "--------------------------------------------------------------------------------------------------------------------------------------------"
  }
  {
    printf "%-24s %-22s %-20s %-20s %-12s %-18s %-16s %-18s\n", $1, $2, $3, $4, $5, $6, $7, $8
  }'
