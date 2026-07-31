# p6-gh-workflow-distribute

Distributes managed workflow files to target repositories across multiple GitHub
orgs, creating PRs with `auto-approve` and `auto-merge` labels.

## Structure

```text
workflow_files/
├── common/          # created or updated in every target
└── <org>/           # org-specific, UPDATE-ONLY (build.yml)

repos/
└── <org>.txt        # one owner/repo per line

bin/
├── distribute.sh    # clone → copy → signed commit → PR → label
└── generate-repos.sh  # refresh repos/*.txt from GitHub API
```

## Common versus org-specific

The two directories have deliberately different creation semantics.

Files in `common/` are **created or updated** unconditionally. Every repo needs
them regardless of what it builds: approval, enqueue, labelling, title lint,
stale, release.

Files in `<org>/` are **update-only** and **archetype-preserving**.

The pack holds exactly one `build.yml` per org, naming one build action. That
assumption does not survive the fleet: `p6m7g8` spans five archetypes across 30
repos, and `pgollucci` and `luckydoganimalrescue` disagree with their own
template in half their targets. A straight copy would rewrite a correct
`p6-cdk-construct-build` to `p6-repo-build` and break that repo's CI.

So the template supplies the **structure** (triggers, concurrency, queue-ref
handling, permissions) and the target keeps its own build **action**. Every repo
gets the merge-queue fixes without having its archetype reassigned by whichever
org it happens to live in.

Four cases, and only the last writes an unmodified template:

| Target's `build.yml` | Behavior |
| --- | --- |
| absent | skipped, never created |
| present, 0 p6 build refs | skipped, fully bespoke |
| present, >1 p6 build refs | skipped, ambiguous |
| present, exactly 1 p6 build ref | template copied, build action substituted back |

Measured across all 156 targets: 148 have exactly one build ref, 6 have no
`build.yml`, and 2 are bespoke (`p6-template-uv`,
`p6-template-sam-eslint-pnpm-ts-flatfile`).

Six targets have no `build.yml` and will not receive one: `p6-gh-manager`,
`p6-sso-scim`, `rustenv`, `p6huggingface`, `p6-ldar-year-end-collage`,
`p6-ai-agent-skills`.

**To onboard one of them**, commit a `build.yml` to the target by hand, choosing
the archetype that repo needs. Distribution maintains it from the next run
onward, preserving the action you chose.

Every skip and every substitution is reported as a `::notice::` including the
repo name, so it appears in the run summary rather than only inside the collapsed
per-repo log group.

### Known limitation

Archetype preservation covers the build **action**. If a target's `build.yml`
diverges from its org template structurally — different jobs, extra steps — that
structure is still replaced. The two fully bespoke targets are skipped entirely
for this reason, but a partially-diverged one would not be detected.

## Orgs

Every org ships a `build.yml`. The action named below is what a target's existing
`build.yml` gets rewritten to, not what its repos necessarily use today.

| Org | Targets | build action | Notes |
| --- | --- | --- | --- |
| `p6m7g8-dotfiles` | 118 | `p6df-build` | matches reality, 117 of 118 |
| `p6m7g8-actions` | 35 | `p6-repo-build` | adds concurrency and queue-ref handling |
| `p6m7g8` | 30 | `p6-repo-build` | 5 archetypes present, mismatch |
| `pgollucci` | 4 | `p6-next-build` | mismatch |
| `luckydoganimalrescue` | 4 | `p6-next-build` | mismatch |
| `continue-learning` | 0 | `p6-repo-build` | target list intentionally empty |

## Usage

### Distribute (workflow_dispatch only)

```yaml
- uses: p6m7g8-actions/p6-gh-workflow-distribute@main
  with:
    gh_token: ${{ secrets.P6_A_GH_TOKEN }}
```

### Limit to specific orgs

```yaml
- uses: p6m7g8-actions/p6-gh-workflow-distribute@main
  with:
    gh_token: ${{ secrets.P6_A_GH_TOKEN }}
    orgs: "p6m7g8-dotfiles p6m7g8-actions"
```

### Refresh repo lists

```bash
ROOT_DIR=. GH_TOKEN=<token> bin/generate-repos.sh
```

## Commits are signed

Commits are created through the GraphQL `createCommitOnBranch` mutation rather
than `git commit` and `git push`. Every target enforces a `required_signatures`
rule, and a commit made by `git commit` on a runner has no key to sign with, so
the merge queue rejects it with `Commits must have verified signatures`. Commits
made by the mutation are signed by GitHub itself, so no signing key has to be
provisioned on the runner or rotated later.

The commit is built on a `<branch>-staging` ref and the real branch is then moved
onto it in one update. Resetting the PR branch to base first would momentarily
make it equal the PR's base commit; GitHub sees an empty diff, closes the PR, and
creating the commit a second later does not reopen it.

## Retiring a managed file

Add its bare filename to `workflow_files/retired.txt`. Only names listed there
are ever deleted from a target, so a typo in the pack cannot remove a repo's own
bespoke workflows. A name that is both retired and still present in the pack is a
hard startup error.
