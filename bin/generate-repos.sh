#!/usr/bin/env bash
set -euo pipefail

# Regenerates repos/<org>.txt from the GitHub API.
# Usage: generate-repos.sh [org1 org2 ...]
# If no args, regenerates all orgs that have an existing repos/*.txt file.
#
# Environment:
#   GH_TOKEN  - GitHub token with read:org scope (required)
#   ROOT_DIR  - path to the p6-gh-distributor repo root (required)

if [[ $# -gt 0 ]]; then
  orgs=("$@")
else
  orgs=()
  for f in "$ROOT_DIR/repos/"*.txt; do
    orgs+=("$(basename "$f" .txt)")
  done
fi

for org in "${orgs[@]}"; do
  echo "Generating repos/$org.txt ..."
  gh repo list "$org" --limit 1000 --json nameWithOwner,isArchived,isFork \
    -q '.[] | select(.isArchived == false and .isFork == false) | .nameWithOwner' \
    | grep -v '/\.github$' \
    | grep -v 'p6m7g8-actions/p6-gh-distributor$' \
    | sort > "$ROOT_DIR/repos/$org.txt"
  echo "  $(wc -l < "$ROOT_DIR/repos/$org.txt") repos written."
done
