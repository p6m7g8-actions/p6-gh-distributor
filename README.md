# p6-gh-distributor

Distributes managed workflow files to target repositories across multiple GitHub
orgs, creating PRs with `auto-approve` and `auto-merge` labels.

## Structure

```text
workflow_files/
├── common/          # distributed to all orgs
└── <org>/           # org-specific overrides (e.g. build.yml)

repos/
└── <org>.txt        # one owner/repo per line

bin/
├── distribute.sh    # clone → copy → PR → label
└── generate-repos.sh  # refresh repos/*.txt from GitHub API
```

## Orgs

| Org | build action |
| --- | --- |
| `p6m7g8-dotfiles` | `p6df-build` |
| `p6m7g8-actions` | `p6-build` + concurrency + lint_pr_title |
| `p6m7g8` | `p6-build` |
| `pgollucci` | `next-build` |
| `luckydoganimalrescue` | `next-build` |

## Usage

### Distribute (workflow_dispatch only)

```yaml
- uses: p6m7g8-actions/p6-gh-distributor@main
  with:
    gh_token: ${{ secrets.P6_A_GH_TOKEN }}
```

### Limit to specific orgs

```yaml
- uses: p6m7g8-actions/p6-gh-distributor@main
  with:
    gh_token: ${{ secrets.P6_A_GH_TOKEN }}
    orgs: "p6m7g8-dotfiles p6m7g8-actions"
```

### Refresh repo lists

```bash
ROOT_DIR=. GH_TOKEN=<token> bin/generate-repos.sh
```
