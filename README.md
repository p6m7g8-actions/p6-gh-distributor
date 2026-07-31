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

Files in `<org>/` are **update-only**. They are refreshed where the target
already has them and never created where it does not. The only such file is
`build.yml`, which names one build archetype per org, and that assumption does
not survive contact with the fleet: `p6m7g8` alone spans five archetypes across
30 repos. Creating `build.yml` where absent would hand a repo a build it never
asked for, chosen by which org it happens to live in, and a library or data repo
may legitimately not want one at all.

Six targets have no `build.yml` today and will not receive one: `p6-gh-manager`,
`p6-sso-scim`, `rustenv`, `p6huggingface`, `p6-ldar-year-end-collage`,
`p6-ai-agent-skills`.

**To onboard one of them**, commit a `build.yml` to the target by hand, choosing
the archetype that repo actually needs. Distribution takes over maintaining it
from the next run onward. There is no way to request one from here, by design.

The skip is reported as a `::notice::` including the repo name, so it appears in
the run summary rather than only inside the collapsed per-repo log group.

### Known limitation

Update-only stops the distributor from *inventing* builds. It does **not** fix
the archetype mismatch for repos that already have a `build.yml` — those are
still overwritten with their org's single flavor. Against current targets that
would rewrite 18 of 30 in `p6m7g8`, and 2 of 4 in each of `pgollucci` and
`luckydoganimalrescue`, with the wrong build action.

Do not run an unscoped distribution against those three orgs until a per-repo
flavor selector exists. `p6m7g8-dotfiles` is unaffected: 117 of its 118 targets
use `p6df-build`, matching its template.

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
