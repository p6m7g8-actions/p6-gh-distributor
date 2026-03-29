#!/usr/bin/env bash
set -euo pipefail

# Distributes workflow_files/ to target repos, creating PRs with auto-approve + auto-merge labels.
#
# Environment:
#   GH_TOKEN      - GitHub token (required)
#   ROOT_DIR      - path to the p6-gh-distributor repo root (required)
#   BRANCH        - branch name in target repos (default: github-actions/file-distribution)
#   COMMIT_MSG    - commit message (default: chore: distribute managed files)
#   PR_TITLE      - PR title (default: chore: distribute managed files)
#   PR_BODY       - PR body
#   BOT           - reviewer username (default: p6m7g8-automation)
#   ORGS          - space-separated org list override (default: all repos/*.txt)

BRANCH="${BRANCH:-github-actions/file-distribution}"
COMMIT_MSG="${COMMIT_MSG:-chore: distribute managed files}"
PR_TITLE="${PR_TITLE:-chore: distribute managed files}"
PR_BODY="${PR_BODY:-Distributes managed workflow files from p6m7g8-actions/p6-gh-distributor.}"
BOT="${BOT:-p6m7g8-automation}"

distribute_to_repo() {
  local repo="$1"
  local org="${repo%%/*}"

  echo "::group::Processing $repo"

  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  gh repo clone "$repo" "$tmp" -- --depth=1 --quiet

  pushd "$tmp" > /dev/null

  git config user.name "github-actions"
  git config user.email "github-actions@github.com"
  git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${repo}.git"

  git checkout -B "$BRANCH"

  # Copy common files
  mkdir -p .github/workflows
  cp "$ROOT_DIR/workflow_files/common/"* .github/workflows/

  # Apply org-specific overrides
  if [[ -d "$ROOT_DIR/workflow_files/$org" ]]; then
    cp "$ROOT_DIR/workflow_files/$org/"* .github/workflows/
  fi

  if git diff --quiet && git diff --cached --quiet; then
    echo "No changes for $repo, skipping."
    popd > /dev/null
    echo "::endgroup::"
    return
  fi

  git add -A
  git commit -m "$COMMIT_MSG" --signoff
  git push origin "$BRANCH" --force

  # Create PR; fall back to fetching existing PR number if branch already has one
  local pr_url pr_number
  pr_url=$(gh pr create \
    --title "$PR_TITLE" \
    --body "$PR_BODY" \
    --base main \
    --head "$BRANCH" \
    --repo "$repo" \
    --reviewer "$BOT" 2>/dev/null) || true

  pr_number=$(gh pr view "$BRANCH" --repo "$repo" --json number -q '.number' 2>/dev/null) || true

  if [[ -n "$pr_number" ]]; then
    # Re-label with automation token (workaround: github.token can't add labels in some contexts)
    gh api -X DELETE "repos/${repo}/issues/${pr_number}/labels/auto-approve" 2>/dev/null || true
    gh api -X DELETE "repos/${repo}/issues/${pr_number}/labels/auto-merge"   2>/dev/null || true
    gh api "repos/${repo}/issues/${pr_number}/labels" \
      -f "labels[]=auto-approve" \
      -f "labels[]=auto-merge"
  fi

  popd > /dev/null
  echo "::endgroup::"
}

# Build list of repos to process
if [[ -n "${ORGS:-}" ]]; then
  # Override: specific orgs only
  for org in $ORGS; do
    repos_file="$ROOT_DIR/repos/$org.txt"
    [[ -f "$repos_file" ]] || { echo "Warning: $repos_file not found, skipping."; continue; }
    while IFS= read -r repo; do
      [[ -z "$repo" || "$repo" == \#* ]] && continue
      distribute_to_repo "$repo"
    done < "$repos_file"
  done
else
  # Default: all repos/*.txt
  for repos_file in "$ROOT_DIR/repos/"*.txt; do
    while IFS= read -r repo; do
      [[ -z "$repo" || "$repo" == \#* ]] && continue
      distribute_to_repo "$repo"
    done < "$repos_file"
  done
fi
