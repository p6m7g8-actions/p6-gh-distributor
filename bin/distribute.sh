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

  # The commit this distribution is based on. Captured before anything is
  # modified, and reused as both the branch base and the `expectedHeadOid`
  # optimistic-concurrency guard on the commit mutation.
  local base_sha
  base_sha=$(git rev-parse HEAD)

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

  # Commit through the API rather than `git commit` + `git push`.
  #
  # Every target repo enforces a `required_signatures` rule, and a commit made
  # by `git commit` on a runner has no key to sign with. Such a commit is
  # accepted by the push but can never be enqueued: the merge queue rejects it
  # with "Commits must have verified signatures". That is the second of the two
  # reasons no distribution PR had ever merged, and it is invisible from the PR
  # page, which shows every required check green.
  #
  # Commits created by `createCommitOnBranch` are signed by GitHub itself, so
  # they verify without provisioning or rotating a signing key on the runner.
  # The tradeoff is that the file set has to be sent explicitly, which is what
  # the diff below computes.
  local name_status additions deletions
  name_status=$(git diff --cached --name-status "$base_sha")

  # Renames arrive as `R100<TAB>old<TAB>new` and must become a delete plus an
  # add; the API has no rename operation.
  additions=$(
    printf '%s\n' "$name_status" | awk -F'\t' '
      $1 ~ /^[AM]/ { print $2 }
      $1 ~ /^R/    { print $3 }
    ' | while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      jq -n --arg path "$p" --arg contents "$(base64 < "$p" | tr -d '\n')" \
        '{path: $path, contents: $contents}'
    done | jq -s '.'
  )
  deletions=$(
    printf '%s\n' "$name_status" | awk -F'\t' '$1 ~ /^[DR]/ { print $2 }' \
      | jq -R 'select(length > 0) | {path: .}' | jq -s '.'
  )

  # Build the commit on a staging branch, then move the real branch to it in a
  # single ref update.
  #
  # The obvious version of this — reset $BRANCH to base, then commit onto it —
  # cannot be used. `createCommitOnBranch` requires an existing branch, so the
  # reset has to happen first, and that momentarily leaves $BRANCH pointing at
  # exactly the PR's base commit. GitHub sees an open PR with an empty diff and
  # closes it, and creating the commit a second later does not reopen it. Going
  # through staging means $BRANCH advances from its old commit straight to the
  # new one and is never equal to base.
  local staging="${BRANCH}-staging"
  if gh api "repos/${repo}/git/ref/heads/${staging}" > /dev/null 2>&1; then
    gh api -X PATCH "repos/${repo}/git/refs/heads/${staging}" \
      -f "sha=$base_sha" -F force=true > /dev/null
  else
    gh api -X POST "repos/${repo}/git/refs" \
      -f "ref=refs/heads/${staging}" -f "sha=$base_sha" > /dev/null
  fi

  # `--signoff` was previously passed to `git commit`; the trailer is now part
  # of the message body sent to the API.
  local commit_body commit_oid
  commit_body="Signed-off-by: github-actions <github-actions@github.com>"

  jq -n \
    --arg repo "$repo" \
    --arg branch "$staging" \
    --arg oid "$base_sha" \
    --arg headline "$COMMIT_MSG" \
    --arg body "$commit_body" \
    --argjson additions "$additions" \
    --argjson deletions "$deletions" \
    '{
      query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
      variables: {
        input: {
          branch: { repositoryNameWithOwner: $repo, branchName: $branch },
          expectedHeadOid: $oid,
          message: { headline: $headline, body: $body },
          fileChanges: { additions: $additions, deletions: $deletions }
        }
      }
    }' > "$tmp/commit-payload.json"

  commit_oid=$(gh api graphql --input "$tmp/commit-payload.json" \
    --jq '.data.createCommitOnBranch.commit.oid')
  if [[ -z "$commit_oid" ]]; then
    echo "::error::createCommitOnBranch returned no commit for $repo" >&2
    gh api -X DELETE "repos/${repo}/git/refs/heads/${staging}" > /dev/null 2>&1 || true
    return 1
  fi

  # Move the real branch onto the finished commit, then drop staging. Any open
  # PR follows the ref and stays open, because it never saw an empty diff.
  if gh api "repos/${repo}/git/ref/heads/${BRANCH}" > /dev/null 2>&1; then
    gh api -X PATCH "repos/${repo}/git/refs/heads/${BRANCH}" \
      -f "sha=$commit_oid" -F force=true > /dev/null
  else
    gh api -X POST "repos/${repo}/git/refs" \
      -f "ref=refs/heads/${BRANCH}" -f "sha=$commit_oid" > /dev/null
  fi
  gh api -X DELETE "repos/${repo}/git/refs/heads/${staging}" > /dev/null 2>&1 || true

  echo "Created signed commit $commit_oid on $BRANCH"

  # Create PR; fall back to fetching existing PR number if branch already has one
  local pr_number
  gh pr create \
    --title "$PR_TITLE" \
    --body "$PR_BODY" \
    --base main \
    --head "$BRANCH" \
    --repo "$repo" \
    --reviewer "$BOT" > /dev/null 2>&1 || true

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
