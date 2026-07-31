#!/usr/bin/env bash
# Exercises distribute.sh's startup validation of workflow_files/<org>/build.yml.
#
# Runs against scratch packs with an EMPTY target list, so nothing is cloned and
# no token is needed: the validation runs before any repo is touched. That is the
# whole point of doing it up front, and it is what makes it testable in CI.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SCRIPT="$PWD/bin/distribute.sh"
fails=0

scratch() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/repos" "$t/workflow_files/common" "$t/workflow_files/testorg"
  cp workflow_files/common/* "$t/workflow_files/common/" 2>/dev/null
  cp workflow_files/retired.txt "$t/workflow_files/" 2>/dev/null
  printf '%s' "$1" > "$t/workflow_files/testorg/build.yml"
  : > "$t/repos/testorg.txt"
  printf '%s' "$t"
}

check() {
  local name="$1" want="$2" body="$3" t rc
  t=$(scratch "$body")
  GH_TOKEN=unused ROOT_DIR="$t" ORGS=testorg bash "$SCRIPT" > /dev/null 2>&1
  rc=$?
  rm -rf "$t"
  if [[ "$rc" == "$want" ]]; then
    echo "ok    $name (exit $rc)"
  else
    echo "FAIL  $name: expected exit $want, got $rc"
    fails=$((fails + 1))
  fi
}

ONE='jobs:
  build:
    steps:
      - uses: p6m7g8-actions/p6-repo-build@main
'
check "one build action is valid" 0 "$ONE"

check "zero build actions is rejected" 2 'jobs:
  build:
    steps:
      - uses: actions/checkout@v4
'

# Two actions matter as much as zero: every target would mismatch a two-line
# want and the whole org would be skipped with per-target notices.
check "two build actions are rejected" 2 'jobs:
  a:
    steps:
      - uses: p6m7g8-actions/p6-repo-build@main
  b:
    steps:
      - uses: p6m7g8-actions/p6-cdk-build@main
'

# The extractor must tolerate the YAML forms that are equally valid, or a
# reformatted template silently disables an org.
check "extra whitespace still resolves" 0 'jobs:
  build:
    steps:
      - uses:   p6m7g8-actions/p6-repo-build@main
'
check "quoted value still resolves" 0 "jobs:
  build:
    steps:
      - uses: 'p6m7g8-actions/p6-repo-build@main'
"
# A commented-out step must not count as a second action.
check "commented step is ignored" 0 'jobs:
  build:
    steps:
      # - uses: p6m7g8-actions/p6-cdk-build@main
      - uses: p6m7g8-actions/p6-repo-build@main
'

# The real pack must always pass; this is the regression guard that matters.
t=$(mktemp -d); mkdir -p "$t/repos"; ln -s "$PWD/workflow_files" "$t/workflow_files"; : > "$t/repos/none.txt"
GH_TOKEN=unused ROOT_DIR="$t" ORGS=none bash "$SCRIPT" > /dev/null 2>&1
rc=$?; rm -rf "$t"
if [[ "$rc" == 0 ]]; then echo "ok    the real pack passes validation (exit 0)"
else echo "FAIL  the real pack is invalid: exit $rc"; fails=$((fails + 1)); fi

if (( fails > 0 )); then echo "$fails failure(s)"; exit 1; fi
echo "all pack-validation checks passed"
