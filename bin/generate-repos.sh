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
  # Filtering happens in jq, not in a grep chain.
  #
  # `grep -v` exits 1 when it emits no lines, and under `set -euo pipefail` that
  # killed the whole run on the FIRST org whose filtered list came out empty --
  # continue-learning, whose only non-fork repo is `.github`. Because it sorts
  # first, every other org silently never regenerated, which is how repos/*.txt
  # drifted 35 entries out of date without anyone seeing an error.
  #
  # Doing it in jq also lets the self-exclusion be a real name rather than a
  # pattern: it was still `p6-gh-distributor`, this repo's pre-rename name, so
  # after the rename the distributor would have started distributing to itself.
  gh repo list "$org" --limit 1000 --json nameWithOwner,isArchived,isFork \
    -q '.[]
        | select(.isArchived == false and .isFork == false)
        | .nameWithOwner
        | select(endswith("/.github") | not)
        | select(. != "p6m7g8-actions/p6-gh-workflow-distribute")' \
    | sort > "$ROOT_DIR/repos/$org.txt"
  echo "  $(wc -l < "$ROOT_DIR/repos/$org.txt") repos written."
done
