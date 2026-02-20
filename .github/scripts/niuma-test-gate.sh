#!/usr/bin/env bash
set -euo pipefail

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

echo "[gate] running for PR #$PR_NUMBER"
echo "[gate] mix deps.get"
mix deps.get

echo "[gate] mix format --check-formatted"
mix format --check-formatted

echo "[gate] mix test"
mix test

echo "[gate] all checks passed"
