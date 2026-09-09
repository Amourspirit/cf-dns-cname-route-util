# AGENTS.md

Single self-contained bash script (`src/tunnel_route.sh`) wrapping the Cloudflare DNS API to manage proxied CNAME records for tunnel routing. No build, test, or lint tooling.

## Running it

- Entrypoint: `./src/tunnel_route.sh [options] <command>`
- Commands: `enable`, `disable`, `rid`, `status`, `routes`, `disable-route <record>`, `help`.
- Config comes from a `.env` discovered by walking up parent dirs from the script location (or `--cf-env-file` / `CF_ENV_FILE`). CLI `--cf-*` overrides beat `.env`.

## Gotchas

- There are NO tests and no CI. The script mutates real Cloudflare DNS via the live API — never run it cleanly or against production data without care. `disable` refuses to delete on target mismatch unless `CF_ALLOW_DELETE_MISMATCH=true`.
- `.env` holds real credentials and is gitignored, as is the `.tracked_routes` registry sidecar (defaulting to `${XDG_STATE_HOME:-$HOME}/cf-dns-cname-route/`). Never commit or print token values.

## Domain language

CONTEXT.md defines the shared vocabulary: **route** (a `(zone, record)` pair + tunnel CNAME target), **tracked route** (recorded in the registry), **registry** (the `.tracked_routes` sidecar), **current route** (the loaded env's route), **other-zone route** (tracked but in a different zone than loaded). Follow the "avoid" lists there — e.g. call it the registry, not a list/config/database.

## Editing

- One file, plain bash (`set -euo pipefail`). Read the whole script before changing it; logic is interleaved (env load, arg parsing, registry helpers, per-command functions).
- Registry parsing relies on tab-delimited `zone\trecord\ttarget` lines — preserve tab separators and the dedup-by-`(zone, record)` behavior (`registry_track`/`registry_untrack`).
