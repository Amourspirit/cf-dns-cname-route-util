# Cloudflare Tunnel DNS Route Helper

A small shell utility to manage a single Cloudflare CNAME record used for tunnel routing.

The script supports enabling, disabling, querying record ID, and checking status for a configured DNS record.

## Features

- Create or update a proxied CNAME route (`enable`)
- Delete a CNAME route safely (`disable`)
- Print record ID (`rid`)
- Inspect route state (`status`)
- Works with both `bash` and `zsh`
- Supports `.env` auto-discovery and CLI overrides for all key runtime variables
- Optional debug logging with `--debug`

## Requirements

- `bash` (script shebang uses `#!/usr/bin/env bash`)
- `curl`
- `jq`
- Cloudflare API token with DNS permissions for the target zone

## Quick Start

1. Clone the repository.
2. Create your local env file from the template:

```bash
cp .env.example .env
```

3. Edit `.env` and set your real values.
4. Run a command:

```bash
./src/tunnel_route.sh status
```

## Commands

```text
enable     Create the Cloudflare CNAME route if it does not exist.
disable    Delete the Cloudflare CNAME route if it exists.
rid        Print the Cloudflare DNS record ID for CF_RECORD_NAME.
status     Show status of the Cloudflare CNAME record.
help       Show help.
```

Examples:

```bash
./src/tunnel_route.sh enable
./src/tunnel_route.sh disable
./src/tunnel_route.sh rid
./src/tunnel_route.sh status
./src/tunnel_route.sh --debug status
```

## CLI Options

```text
-h, --help
-v, --verbose
-q, --quiet
-d, --debug
    --quite (alias for --quiet)

--cf-zone-id VALUE
--cf-api-token VALUE
--cf-record-name VALUE
--cf-tunnel-cname VALUE
--cf-tunnel-id VALUE
--cf-env-file PATH
--cf-allow-delete-mismatch BOOL
--cf-connect-timeout SECONDS
--cf-max-time SECONDS
--cf-retry-count COUNT
```

Notes:

- Both `--option value` and `--option=value` formats are supported.
- CLI overrides take precedence over values loaded from `.env`.
- If `--cf-tunnel-id` is provided and `--cf-tunnel-cname` is not, `CF_TUNNEL_CNAME` is derived as:
  - `${CF_TUNNEL_ID}${CF_TUNNEL_CNAME_SUFFIX}`

## Configuration

The script reads environment values from:

1. `CF_ENV_FILE` if provided (file path or directory containing `.env`)
2. Otherwise, parent-directory auto-discovery from script location

### Required

- `CF_ZONE_ID`
- `CF_API_TOKEN`
- `CF_RECORD_NAME`

For `enable` and `disable`, also required:

- `CF_TUNNEL_CNAME` (or `CF_TUNNEL_ID` so the script can derive it)

### Optional

- `CF_TUNNEL_ID`
- `CF_TUNNEL_CNAME_SUFFIX` (default: `.cfargotunnel.com`)
- `CF_ENV_FILE`
- `CF_ALLOW_DELETE_MISMATCH` (set `true` to allow deleting mismatched target)
- `CF_CONNECT_TIMEOUT` (default: `5`)
- `CF_MAX_TIME` (default: `20`)
- `CF_RETRY_COUNT` (default: `2`)

## Status Output

`status` resolves to these states:

- `absent`: no matching CNAME exists
- `present`: CNAME exists, but expected target not provided
- `active`: CNAME exists and matches `CF_TUNNEL_CNAME`
- `inactive`: CNAME exists but does not match `CF_TUNNEL_CNAME`

With `--quiet`, only the state string is printed.

## Safety Behavior

- `disable` refuses deletion if the existing target differs from `CF_TUNNEL_CNAME`
- Override with `CF_ALLOW_DELETE_MISMATCH=true` (or corresponding CLI flag)
- API errors fail fast with explicit error output

## Debugging

Enable debug logs:

```bash
./src/tunnel_route.sh --debug status
```

Debug logs are written to stderr and include parse/load/override checkpoints and API request metadata.

## Security

- Never commit real credentials.
- Keep secrets in local `.env` only.
- Rotate Cloudflare credentials immediately if leakage is suspected.

## License

MIT. See [LICENSE](LICENSE).
