# Archetype build templates

One `build.yml` per build archetype, named for the action it invokes. Used when a
target's own build action has no matching org-level template, so a repo gets the
managed `build.yml` for *its* archetype rather than its org's.

Selection is by the action a target already uses. An org-level
`workflow_files/<org>/build.yml` still wins when it matches, so
`p6m7g8-actions` keeps its concurrency and queue-ref variant and
`p6m7g8-dotfiles` keeps its own.

## Why some archetypes are absent

`p6-cdk-build` is deliberately **not** here and must not be added. It requires
`aws_role`, `aws_session_name`, `cdk_deploy_account` and `cdk_deploy_region`, and
those are per-repo AWS values that no shared template can supply. Targets on that
archetype keep their own `build.yml`; distribution skips them, which is correct.

Before adding a template, check the action's declared inputs. If any `required:
true` input is a per-repo value, it does not belong here.

| Archetype | Required inputs | Templated |
| --- | --- | --- |
| `p6-repo-build` | `gh_token` | yes |
| `p6df-build` | `gh_token` | yes |
| `p6-cdk-construct-build` | none | yes |
| `p6-next-build` | none | yes |
| `p6-cdk-build` | 4 per-repo AWS values | no, by design |
