#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[gate] $*"
}

usage() {
  echo "usage: $0 <pr-number>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

PR_NUMBER="$1"
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "invalid pr-number: $PR_NUMBER" >&2
  usage
  exit 2
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN is required" >&2
  exit 2
fi

HEAD_REF=$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName')
BASE_REF=$(gh pr view "$PR_NUMBER" --json baseRefName --jq '.baseRefName')
HEAD_SHA=$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid')
BASE_SHA=$(gh pr view "$PR_NUMBER" --json baseRefOid --jq '.baseRefOid')

if [[ -z "$HEAD_REF" || "$HEAD_REF" == "null" ]]; then
  echo "unable to resolve PR head ref for #$PR_NUMBER" >&2
  exit 1
fi

if [[ -z "$BASE_REF" || "$BASE_REF" == "null" ]]; then
  echo "unable to resolve PR base ref for #$PR_NUMBER" >&2
  exit 1
fi

if [[ -z "$HEAD_SHA" || "$HEAD_SHA" == "null" ]]; then
  HEAD_SHA="unknown"
fi

if [[ -z "$BASE_SHA" || "$BASE_SHA" == "null" ]]; then
  BASE_SHA="unknown"
fi

WORK_BRANCH="niuma-gate-$PR_NUMBER"
MERGE_REF_SOURCE=""
MERGE_SHA=""

log "baseline=merge-result"

# 优先使用 GitHub 的 merge ref，确保 gate 在 PR 合并结果基线上执行。
if git fetch origin "pull/${PR_NUMBER}/merge"; then
  MERGE_SHA=$(git rev-parse FETCH_HEAD)
  git checkout -B "$WORK_BRANCH" "$MERGE_SHA"
  MERGE_REF_SOURCE="github-merge-ref"
else
  # merge ref 不可用时，回退到本地 base+head 临时合并。
  log "merge ref unavailable, fallback to local merge"
  git fetch origin "$BASE_REF"
  git fetch origin "$HEAD_REF"
  git checkout -B "$WORK_BRANCH" "origin/$BASE_REF"

  set +e
  MERGE_OUTPUT=$(git -c user.name='niuma-gate' -c user.email='niuma-gate@local' merge --no-ff --no-edit "origin/$HEAD_REF" 2>&1)
  MERGE_STATUS=$?
  set -e

  if [[ $MERGE_STATUS -ne 0 ]]; then
    CONFLICT_FILES=$(git diff --name-only --diff-filter=U || true)
    echo "CONFLICT: failed to merge origin/$HEAD_REF into origin/$BASE_REF" >&2

    if [[ -n "$CONFLICT_FILES" ]]; then
      echo "CONFLICT: files:" >&2
      while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        echo "CONFLICT: $file" >&2
      done <<< "$CONFLICT_FILES"
    fi

    MERGE_SUMMARY=$(printf '%s\n' "$MERGE_OUTPUT" | grep -E 'CONFLICT|Automatic merge failed|^error:' | head -n 20 || true)
    if [[ -z "$MERGE_SUMMARY" ]]; then
      MERGE_SUMMARY=$(printf '%s\n' "$MERGE_OUTPUT" | tail -n 20)
    fi

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "CONFLICT: $line" >&2
    done <<< "$MERGE_SUMMARY"

    git merge --abort >/dev/null 2>&1 || true
    exit 1
  fi

  MERGE_SHA=$(git rev-parse HEAD)
  MERGE_REF_SOURCE="local-merge"
fi

log "merge_ref_source=$MERGE_REF_SOURCE"
log "base_sha=$BASE_SHA"
log "head_sha=$HEAD_SHA"
if [[ -n "$MERGE_SHA" ]]; then
  log "merge_sha=$MERGE_SHA"
fi

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
deps_get_timeout_seconds=180

# 清理历史遗留目录，避免旧的 git 依赖状态污染本次解析。
rm -rf deps/heroicons _build/test/lib/heroicons

for attempt in $(seq 1 "$max_attempts"); do
  if command -v timeout >/dev/null 2>&1; then
    if run_with_log_tail timeout --signal=TERM --kill-after=30 "${deps_get_timeout_seconds}" \
      mix deps.get --only test --check-locked; then
      deps_get_status=0
    else
      deps_get_status=$?
    fi
  else
    if run_with_log_tail mix deps.get --only test --check-locked; then
      deps_get_status=0
    else
      deps_get_status=$?
    fi
  fi
  if [ "$deps_get_status" -eq 0 ]; then
    deps_get_ok=1
    break
  fi

  if [ "$deps_get_status" -eq 124 ]; then
    echo "deps.get timed out on attempt ${attempt}/${max_attempts} after ${deps_get_timeout_seconds}s"
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
