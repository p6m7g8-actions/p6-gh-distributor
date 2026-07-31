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

Files in `<org>/` are **update-only**, and `build.yml` is additionally
**skipped on archetype mismatch**.

The pack holds one `build.yml` per org naming one build action. That does not
survive the fleet: `p6m7g8` spans five archetypes across 30 repos, and
`pgollucci` and `luckydoganimalrescue` disagree with their own template in most
of their targets. A straight copy rewrites a correct `p6-cdk-construct-build` to
`p6-repo-build` and breaks that repo's CI.

Substituting just the `uses:` line back is **not** sufficient, and was tried and
rejected: the preserved action would then be invoked with the *template's*
`with:` block. Those differ per org — `pgollucci` and `luckydoganimalrescue` pass
no inputs at all, `p6m7g8-dotfiles` passes `gh_token` plus `shellcheck: false` —
so a `p6df-build` target under `pgollucci` would silently lose its `gh_token`.
Preserving the action name while replacing its invocation is worse than not
touching the file.

So `build.yml` is written only when the target already agrees with the template
about which build action to use. A mismatched target keeps its file verbatim and
forgoes template updates, which is the correct trade because it is currently
working.

| Target's `build.yml` | Behavior |
| --- | --- |
| absent | skipped, never created |
| no p6 build action | skipped, bespoke |
| build action differs from template | skipped verbatim |
| build action matches template | template written |

Nothing else is gated on this. The merge-queue fixes and `claude-review.yml` ship
from `common/`, which every target receives regardless of archetype.

Six targets have no `build.yml` and will not receive one: `p6-gh-manager`,
`p6-sso-scim`, `rustenv`, `p6huggingface`, `p6-ldar-year-end-collage`,
`p6-ai-agent-skills`.

**To onboard one of them**, commit a `build.yml` to the target by hand, choosing
the archetype that repo needs. If it matches the org template, distribution
maintains it from the next run onward.

Every skip is reported as a `::notice::` naming the repo and both actions, so it
appears in the run summary rather than only inside the collapsed per-repo log
group.

### Known limitations

**Matching targets still lose structural divergence.** When the build action
matches, the whole file is replaced. A target that shares the action but has an
extra job or extra steps loses them. The two fully bespoke targets are skipped
because they reference no p6 build action at all, but a *partially* diverged one
is not detected.

**Mismatched targets receive no `build.yml` updates at all**, including
merge-queue fixes to that file. Against current targets that is 18 of 30 in
`p6m7g8` and 3 of 4 in each of `pgollucci` and `luckydoganimalrescue`. Concretely, if such a
target lacks the `push` trigger on `gh-readonly-queue/**` that lets `build` report
on the queue ref, distribution will not add it, and that gap persists. Everything
shipped from `common/` still reaches them, including `auto-queue.yml` and
`claude-review.yml`.

Some of these mismatches are only pre-rename names (`next-build` versus
`p6-next-build`) rather than genuine archetype differences. Those will start
matching once downstream `uses:` refs are updated to the renamed actions, which
shrinks this set without any change here.

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
