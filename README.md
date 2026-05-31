# shi-env

Unified declarative deployment topology plugin for shikki.

Provides a single source of truth for all deployment environments across workspaces, addressable as `<workspace>.<project>.<environment>.<service>`.

## Sub-spec #1 — inventory schema

Ships the schema layer only: YAML manifest parsing, inheritance resolution, linter, and four read-only verbs (`shi env list / show / diff / lint`). No remote-host mutation.

## Install

```sh
shi plugin install shi-env
```

Or add to your distribution profile manifest.

## Verbs

| Verb | Description |
|---|---|
| `shi env list` | All environments across workspaces. |
| `shi env show <workspace>.<project>.<env>` | Resolved (post-inheritance) manifest. |
| `shi env diff <env1> <env2>` | Diff two resolved manifests. |
| `shi env lint [<addr>]` | Validate schema, secret refs, dep DAG, port collisions. |

## Spec

`features/shi-env-inventory-schema-2026-05-31.md` (in shikki monorepo) — @db is canonical.
