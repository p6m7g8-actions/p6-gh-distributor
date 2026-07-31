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

# A scratch pack that quietly loses common/ or retired.txt would verify the guard
# against a pack that no longer resembles the real one, while every check still
# passed. So a failed copy aborts the suite rather than being discarded.
scratch() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/repos" "$t/workflow_files/common" "$t/workflow_files/testorg"
  if ! cp workflow_files/common/* "$t/workflow_files/common/"; then
    echo "FATAL: cannot populate scratch common/ from workflow_files/common/" >&2
    exit 1
  fi
  if ! cp workflow_files/retired.txt "$t/workflow_files/"; then
    echo "FATAL: cannot copy workflow_files/retired.txt into the scratch pack" >&2
    exit 1
  fi
  printf '%s' "$1" > "$t/workflow_files/testorg/build.yml"
  : > "$t/repos/testorg.txt"
  printf '%s' "$t"
}

# check <name> <expected-exit> <build.yml body> [expected-stderr-substring]
#
# The substring matters as much as the code. distribute.sh exits 2 from three
# distinct startup paths -- retired.txt path escape, retired-but-present, and this
# count guard -- so asserting only `$rc` would let any future earlier exit-2 path
# make these cases print ok while the guard is never reached. That is the same
# "finding nothing, skipping everything, reading as success" failure this suite
# exists to prevent. It also pins the message the README advertises.
check() {
  local name="$1" want="$2" body="$3" expect="${4:-}" t rc out
  t=$(scratch "$body")
  out=$(GH_TOKEN=unused ROOT_DIR="$t" ORGS=testorg bash "$SCRIPT" 2>&1)
  rc=$?
  rm -rf "$t"
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL  $name: expected exit $want, got $rc"
    fails=$((fails + 1))
    return
  fi
  if [[ -n "$expect" && "$out" != *"$expect"* ]]; then
    echo "FAIL  $name: exit $rc was right but message did not contain '$expect'"
    fails=$((fails + 1))
    return
  fi
  echo "ok    $name (exit $rc)"
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
' "expected exactly 1"

# Two actions matter as much as zero: every target would mismatch a two-line
# want and the whole org would be skipped with per-target notices.
check "two build actions are rejected" 2 'jobs:
  a:
    steps:
      - uses: p6m7g8-actions/p6-repo-build@main
  b:
    steps:
      - uses: p6m7g8-actions/p6-cdk-build@main
' "expected exactly 1"

# Pins the limitation README.md documents: a name outside [a-z0-9-] extracts to
# zero actions and aborts the run. Asserted here so widening the character class
# cannot silently falsify the README.
check "uppercase action name aborts the run (README limitation)" 2 'jobs:
  build:
    steps:
      - uses: p6m7g8-actions/P6-Repo-Build@main
' "expected exactly 1"

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
