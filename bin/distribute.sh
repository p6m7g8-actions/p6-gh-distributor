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
RETIRED_FILE="$ROOT_DIR/workflow_files/retired.txt"

# Retired managed files, validated once before any repo is touched. Only names
# listed here are ever deleted from a target, so a repo's own bespoke workflows
# cannot be removed by a typo in the pack.
RETIRED=()
if [[ -f "$RETIRED_FILE" ]]; then
  while IFS= read -r name; do
    name="${name%%#*}"
    name="$(printf '%s' "$name" | tr -d '[:space:]')"
    [[ -z "$name" ]] && continue

    # Reject anything that could escape .github/workflows/.
    case "$name" in
      */*|*..*)
        echo "::error::retired.txt entry must be a bare filename, got '$name'" >&2
        exit 2
        ;;
    esac

    # A file cannot be both distributed and deleted.
    if [[ -e "$ROOT_DIR/workflow_files/common/$name" ]]; then
      echo "::error::'$name' is listed in retired.txt but still exists in workflow_files/common/" >&2
      exit 2
    fi
    for org_dir in "$ROOT_DIR/workflow_files/"*/; do
      [[ -d "$org_dir" ]] || continue
      if [[ -e "$org_dir$name" ]]; then
        echo "::error::'$name' is listed in retired.txt but still exists in $org_dir" >&2
        exit 2
      fi
    done

    RETIRED+=("$name")
  done < "$RETIRED_FILE"
fi
if (( ${#RETIRED[@]} > 0 )); then
  echo "Retired managed files to remove from targets: ${RETIRED[*]}"
fi

FAILED=()

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

  # Remove files that have been retired from the pack. Copying alone can never
  # do this, which is why a retired file would otherwise persist downstream
  # forever. Scoped to .github/workflows/ and to validated bare filenames.
  local retired
  for retired in ${RETIRED[@]+"${RETIRED[@]}"}; do
    if [[ -f ".github/workflows/$retired" ]]; then
      rm -f ".github/workflows/$retired"
      echo "Removed retired managed file: $retired"
    fi
  done

  # Stage BEFORE testing for changes. `git diff` is blind to untracked files, so
  # checking first meant a brand-new template, or any target missing a managed
  # file, reported "No changes" and was skipped unless some already-tracked file
  # happened to differ too.
  git add -A
  if git diff --cached --quiet; then
    echo "No changes for $repo, skipping."
    popd > /dev/null
    echo "::endgroup::"
    return
  fi

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

# One target must not sink the run. Previously a single failure — a 403 pushing
# to an archived or unreachable repo, say — aborted the whole loop under
# `set -euo pipefail`, silently leaving every later repo undistributed. Now each
# target runs in a subshell that keeps errexit internally, so an intermediate
# failure still stops THAT repo before it can commit or push a bad state, while
# the run continues and reports every failure at the end.
process_repo() {
  local repo="$1" rc=0
  set +e
  ( set -e; distribute_to_repo "$repo" )
  rc=$?
  set -e
  if (( rc != 0 )); then
    echo "::warning::$repo failed (exit $rc); continuing with remaining targets"
    FAILED+=("$repo")
  fi
}

# Build list of repos to process
if [[ -n "${ORGS:-}" ]]; then
  # Override: specific orgs only
  for org in $ORGS; do
    repos_file="$ROOT_DIR/repos/$org.txt"
    [[ -f "$repos_file" ]] || { echo "Warning: $repos_file not found, skipping."; continue; }
    while IFS= read -r repo; do
      [[ -z "$repo" || "$repo" == \#* ]] && continue
      process_repo "$repo"
    done < "$repos_file"
  done
else
  # Default: all repos/*.txt
  for repos_file in "$ROOT_DIR/repos/"*.txt; do
    while IFS= read -r repo; do
      [[ -z "$repo" || "$repo" == \#* ]] && continue
      process_repo "$repo"
    done < "$repos_file"
  done
fi

if (( ${#FAILED[@]} > 0 )); then
  echo "::error::${#FAILED[@]} target(s) failed: ${FAILED[*]}"
  exit 1
fi
echo "All targets processed successfully."
