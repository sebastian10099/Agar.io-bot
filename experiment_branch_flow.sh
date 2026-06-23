#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${1:-/root/local_agent/agent_workspace}"
BASE_BRANCH="${BASE_BRANCH:-prometheus}"
PREFIX="${EXPERIMENT_PREFIX:-experiment/selfdev}"

cd "$REPO"

current="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$current" == experiment/* ]]; then
  echo "Already on experiment branch: $current"
  exit 0
fi

if [[ -n "$(git status --short)" ]]; then
  echo "Refusing to create experiment branch with dirty worktree. Commit or clean first."
  exit 2
fi

git fetch origin "$BASE_BRANCH" >/dev/null 2>&1 || true
git checkout "$BASE_BRANCH"
git pull --ff-only origin "$BASE_BRANCH" >/dev/null 2>&1 || true

branch="$PREFIX-$(date -u +%Y%m%d-%H%M%S)"
git checkout -b "$branch"
git push -u origin "$branch"

echo "Experiment branch ready: $branch"
echo "Use this branch for self-improvement changes. Merge back only after tests/review."
