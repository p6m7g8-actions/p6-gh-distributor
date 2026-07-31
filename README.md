# p6-gh-workflow-distribute

Distributes managed workflow files to target repositories across multiple GitHub
orgs, creating PRs with `auto-approve` and `auto-merge` labels.

## Structure

```text
workflow_files/
├── common/          # created or updated in every target
├── _build/          # one build.yml per archetype, selected by filename
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
`pgollucci` and `luckydoganimalrescue` disagree with their own template in 3 of
their 4 targets. A straight copy rewrites a correct `p6-cdk-construct-build` to
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
| matches the org template | org template written |
| differs, but `_build/<action>.yml` exists | **archetype template written** |
| differs, no archetype template | skipped verbatim |

The archetype fallback is what makes the org template's single build action
non-fatal: a repo receives the managed `build.yml` for *its* archetype rather than
its org's, so the queue-ref trigger reaches repos the org template can never
serve. See `workflow_files/_build/README.md` for which archetypes are templated
and why `p6-cdk-build` deliberately is not.

Everything in `common/` still reaches every target regardless of archetype,
including `auto-queue.yml` and `claude-review.yml`. What a mismatched target does
forgo is anything living in `build.yml` itself — see
[Known limitations](#known-limitations).

Six targets have no `build.yml` and will not receive one. Names are qualified
because `p6-ai-agent-skills` exists in two orgs and only the `pgollucci` one lacks
a build:

- `p6m7g8/p6-gh-manager`
- `p6m7g8/p6-sso-scim`
- `p6m7g8/rustenv`
- `p6m7g8-dotfiles/p6huggingface`
- `luckydoganimalrescue/p6-ldar-year-end-collage`
- `pgollucci/p6-ai-agent-skills`

`p6m7g8/p6-ai-agent-skills` does have a `build.yml`, on `p6-build`, so it counts
as a mismatch rather than a missing build. That is why `p6m7g8` shows 3 in the
`none` column, not 4.

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
merge-queue fixes to that file. Measured today that is 25 of 30 in `p6m7g8`, 3 of
4 in each of `pgollucci` and `luckydoganimalrescue`, and **35 of 35 in
`p6m7g8-actions`** — the largest set, and the one with real consequences, because
that org's template is the one carrying the concurrency and queue-ref handling.
Concretely, if such a target lacks the `push` trigger on `gh-readonly-queue/**`
that lets `build` report on the queue ref, distribution will not add it and the
gap persists. Everything shipped from `common/` still reaches them, including
`auto-queue.yml` and `claude-review.yml`.

**An action name outside `[a-z0-9-]` now aborts the whole run.** The extractor's
character class is also the pack's validator, so an org template naming an action
with an uppercase letter or an underscore no longer degrades to per-target skips —
it exits 2 before any repo is cloned, including for orgs whose templates are fine.
Failing loud on a pack defect is the intent; the blast radius is the whole run.

Some of these mismatches are only pre-rename names (`next-build` versus
`p6-next-build`) rather than genuine archetype differences. Those will start
matching once downstream `uses:` refs are updated to the renamed actions, which
shrinks this set without any change here.

## Orgs

Every org ships a `build.yml`. The action named below is the one a target must
**already** use for the template to be written; nothing is ever rewritten to it.
The mismatch counts are measured, not assumed, and are what a run today would
skip.

| Org | Targets | build action | Would write | Would skip |
| --- | --- | --- | --- | --- |
| `p6m7g8-dotfiles` | 118 | `p6df-build` | 117 | 1 (no `build.yml`) |
| `p6m7g8-actions` | 35 | `p6-repo-build` | 0 | 35, all pre-rename `p6-build` |
| `p6m7g8` | 30 | `p6-repo-build` | 0 | 25 mismatch, 3 none, 2 bespoke |
| `pgollucci` | 4 | `p6-next-build` | 0 | 3 mismatch, 1 none |
| `luckydoganimalrescue` | 4 | `p6-next-build` | 0 | 3 mismatch, 1 none |
| `continue-learning` | 0 | `p6-repo-build` | — | — (target list intentionally empty) |

Measured 2026-07-31 with the same extractor the script uses. Two things this makes
obvious that the previous prose did not:

- **`p6m7g8-actions` would gain nothing from a run today.** All 35 targets still
  say `p6-build` against a template naming `p6-repo-build` — the same archetype
  under its pre-rename name. The rename sweep missed `.github/workflows/` because
  `fd` skips hidden directories, so every one of them reads as a mismatch. Update
  those refs first, or the run delivers no `build.yml` changes to the org whose
  template carries the concurrency and queue-ref handling.
- **`p6m7g8-dotfiles` is the only org where a run does substantial work today**,
  117 of 118.

Pre-rename names currently misreported as mismatches include `p6-build`,
`next-build`, `cdk-build`, and `cdk-construct-build`. Those resolve to matches
once downstream refs are updated; genuine archetype differences (`p6df-build`
under `pgollucci`, for instance) remain.

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

### Run the tests

```bash
./test/pack-validation.sh
```

Exercises the startup validation of `workflow_files/<org>/build.yml`. It needs no
token and no network, because the validation runs before any repo is cloned. Also
run by `smoke.yml` on any PR touching `bin/`, `workflow_files/`, or `test/`.

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
