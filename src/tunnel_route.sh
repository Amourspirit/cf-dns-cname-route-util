#!/usr/bin/env bash
# tunnel_route.sh — enable/disable Cloudflare DNS record for tunnel routing.

set -euo pipefail
CF_TUNNEL_CNAME_SUFFIX="${CF_TUNNEL_CNAME_SUFFIX:-.cfargotunnel.com}"
QUIET=0
VERBOSE=0
DEBUG=0

OVERRIDE_CF_ZONE_ID=""
OVERRIDE_CF_API_TOKEN=""
OVERRIDE_CF_RECORD_NAME=""
OVERRIDE_CF_TUNNEL_CNAME=""
OVERRIDE_CF_TUNNEL_ID=""
OVERRIDE_CF_ENV_FILE=""
OVERRIDE_CF_ALLOW_DELETE_MISMATCH=""
OVERRIDE_CF_CONNECT_TIMEOUT=""
OVERRIDE_CF_MAX_TIME=""
OVERRIDE_CF_RETRY_COUNT=""
CF_ENV_FILE=""

# Absolute directory containing this script (works when called from anywhere)
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"

ENV_DIR=$SCRIPT_DIR

# Traverse upwards until we find .env or hit the file system root
while [[ "$ENV_DIR" != "/" && ! -f "$ENV_DIR/.env" ]]; do
  ENV_DIR="$(dirname "$ENV_DIR")"
done
if [[ -f "$ENV_DIR/.env" ]]; then
  CF_ENV_FILE="$ENV_DIR/.env"
fi


log() {
  if [[ "$QUIET" == "1" ]]; then
    return
  fi
  echo "[tunnel_route] $*"
}

debug() {
  if [[ "$DEBUG" != "1" ]]; then
    return
  fi
  echo "[tunnel_route][debug] $*" >&2
}

print_help() {
  cat <<'EOF'
Usage:
  tunnel_route.sh [options] <command>

Commands:
  enable           Create the Cloudflare CNAME route if it does not exist.
  disable          Delete the Cloudflare CNAME route if it exists.
  rid              Print the Cloudflare DNS record ID for CF_RECORD_NAME.
  status           Show status of the Cloudflare CNAME record.
  routes           List every tracked route and its status.
  disable-route N  Delete a tracked route's CNAME record and untrack it.
  help             Show this help message.

Options:
  -h, --help      Show this help message.
  -v, --verbose   Print verbose output. For status, prints full API JSON.
  -q, --quiet     Print minimal output (automation-friendly).
  -d, --debug     Print debug logs to stderr.
      --quite     Alias for --quiet.
  --cf-zone-id VALUE               Override CF_ZONE_ID.
  --cf-api-token VALUE             Override CF_API_TOKEN.
  --cf-record-name VALUE           Override CF_RECORD_NAME.
  --cf-tunnel-cname VALUE          Override CF_TUNNEL_CNAME.
  --cf-tunnel-id VALUE             Override CF_TUNNEL_ID.
  --cf-env-file PATH               Override CF_ENV_FILE.
  --cf-allow-delete-mismatch BOOL  Override CF_ALLOW_DELETE_MISMATCH.
  --cf-connect-timeout SECONDS     Override CF_CONNECT_TIMEOUT.
  --cf-max-time SECONDS            Override CF_MAX_TIME.
  --cf-retry-count COUNT           Override CF_RETRY_COUNT.

Required environment variables (for enable/disable/rid/status):
  CF_ZONE_ID        Cloudflare Zone ID.
  CF_API_TOKEN      Cloudflare API token with DNS edit permissions.
  CF_RECORD_NAME    DNS record name to manage (for example: app.example.com).

Additionally required:
  CF_TUNNEL_CNAME   Tunnel target (for example: <tunnel-id>.cfargotunnel.com).
                    Required for enable and disable. Optional for status.

Optional environment variables:
  CF_ENV_FILE               Path to .env file, or a directory containing .env.
  CF_ALLOW_DELETE_MISMATCH  Set to true to allow delete when CNAME target differs.

Notes:
  - If CF_TUNNEL_CNAME is unset and CF_TUNNEL_ID is set, CF_TUNNEL_CNAME defaults
    to "${CF_TUNNEL_ID}.cfargotunnel.com".
  - If CF_ENV_FILE is set to a file, that file is loaded directly.
  - If CF_ENV_FILE is set to a directory, CF_ENV_FILE/.env is loaded.
  - If CF_ENV_FILE is unset, parent directories are searched from script location.

Tracked routes:
  - A successful 'enable' records the route in a sidecar registry (.tracked_routes).
    'disable' removes it from the registry.
  - Registry lives in CF_TRACKED_ROUTES, or defaults to
    ${XDG_STATE_HOME:-$HOME}/cf-dns-cname-route/. The directory is auto-created.
  - 'routes' lists every tracked route. Status is queried live for routes in the
    loaded zone; other-zone tracks show 'other-zone'.
  - 'disable-route <record>' deletes and untracks a tracked route. It only works
    for routes in the currently loaded zone; load that zone's env otherwise.
EOF
}

print_usage() {
  echo "Usage: $0 [options] {enable|disable|rid|status|routes|disable-route <record>|help}" >&2
  echo "Run '$0 --help' for details." >&2
}

parse_opt_value() {
  local opt_name="$1"
  local opt_value="${2:-}"
  if [[ -z "$opt_value" ]]; then
    echo "Missing value for ${opt_name}" >&2
    exit 1
  fi
  printf '%s' "$opt_value"
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: ${name}" >&2
    exit 1
  fi
}

load_env() {
  local env_source="${CF_ENV_FILE:-}"

  if [[ -n "$env_source" ]]; then
    if [[ -f "$env_source" ]]; then
      source "$env_source"
      return
    fi
    if [[ -f "$env_source/.env" ]]; then
      source "$env_source/.env"
      return
    fi
    echo "Error: CF_ENV_FILE is set but no env file was found at '$env_source' or '$env_source/.env'." >&2
    exit 1
  fi

  # Absolute directory containing this script (works when called from anywhere)
  local search_dir
  search_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"

  # Traverse upwards until we find .env or hit the file system root
  while [[ "$search_dir" != "/" && ! -f "$search_dir/.env" ]]; do
    search_dir="$(dirname "$search_dir")"
  done

  if [[ ! -f "$search_dir/.env" ]]; then
    echo "Error: Could not find .env in any parent directory." >&2
    exit 1
  fi

  source "$search_dir/.env"
}

require_env() {
  local name="$1"
  local value=""

  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "Invalid environment variable name: ${name}" >&2
    exit 1
  fi

  eval "value=\${$name:-}"

  if [[ -z "$value" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

api_request() {
  local method="$1"
  local url="$2"
  local payload="${3:-}"
  local connect_timeout="${CF_CONNECT_TIMEOUT:-5}"
  local max_time="${CF_MAX_TIME:-20}"
  local retry_count="${CF_RETRY_COUNT:-2}"

  debug "api_request method=${method} url=${url} connect_timeout=${connect_timeout} max_time=${max_time} retry_count=${retry_count} payload_present=$([[ -n "$payload" ]] && echo yes || echo no)"

  if [ -n "$payload" ]; then
    curl --silent --show-error --fail \
      --connect-timeout "$connect_timeout" \
      --max-time "$max_time" \
      --retry "$retry_count" \
      --retry-delay 1 \
      --retry-all-errors \
      -X "$method" "$url" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$payload" || {
        local curl_exit="$?"
        echo "Cloudflare API request failed (${method} ${url}) [curl exit ${curl_exit}]." >&2
        return "$curl_exit"
      }
  else
    curl --silent --show-error --fail \
      --connect-timeout "$connect_timeout" \
      --max-time "$max_time" \
      --retry "$retry_count" \
      --retry-delay 1 \
      --retry-all-errors \
      -X "$method" "$url" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" || {
        local curl_exit="$?"
        echo "Cloudflare API request failed (${method} ${url}) [curl exit ${curl_exit}]." >&2
        return "$curl_exit"
      }
  fi
}

assert_cf_success() {
  local response="$1"
  local operation="$2"
  if [ "$(printf '%s' "$response" | jq -r '.success // false')" != "true" ]; then
    echo "Cloudflare API ${operation} failed: $(printf '%s' "$response" | jq -c '.errors // []')" >&2
    exit 1
  fi
}

lookup_records_response() {
  local response
  local encoded_name
  encoded_name="$(jq -nr --arg value "$CF_RECORD_NAME" '$value|@uri')"
  if ! response="$(api_request GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${encoded_name}&per_page=100")"; then
    exit 1
  fi
  assert_cf_success "$response" "lookup"
  printf '%s' "$response"
}

# Find the DNS record JSON
get_record_json() {
  local response
  response="$(lookup_records_response)"
  printf '%s' "$response" | jq -c --arg name "$CF_RECORD_NAME" 'first(.result[]? | select(.type == "CNAME" and .name == $name)) // empty'
}

get_record_id() {
  local record_json
  record_json="$(get_record_json)"
  if [[ -z "$record_json" ]]; then
    return 0
  fi
  printf '%s' "$record_json" | jq -r '.id // empty'
}

# Enable: create CNAME record
enable_route() {
  local record_json
  record_json="$(get_record_json)"

  if [ -z "$record_json" ]; then
    local payload
    local response
    payload="$(jq -n --arg name "$CF_RECORD_NAME" --arg content "$CF_TUNNEL_CNAME" '{type:"CNAME",name:$name,content:$content,proxied:true}')"
    debug "Creating CNAME record for ${CF_RECORD_NAME} -> ${CF_TUNNEL_CNAME}"
    if ! response="$(api_request POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" "$payload")"; then
      debug "Failed to create CNAME record for ${CF_RECORD_NAME} -> ${CF_TUNNEL_CNAME}"
      exit 1
    fi
    assert_cf_success "$response" "create"
    log "Route enabled: ${CF_RECORD_NAME} -> ${CF_TUNNEL_CNAME}"
    registry_write "$(registry_track "$CF_ZONE_ID" "$CF_RECORD_NAME" "$CF_TUNNEL_CNAME")"
  else
    local record_id existing_content existing_proxied
    local payload response
    record_id="$(printf '%s' "$record_json" | jq -r '.id // empty')"
    existing_content="$(printf '%s' "$record_json" | jq -r '.content // empty')"
    existing_proxied="$(printf '%s' "$record_json" | jq -r '.proxied // false')"
    debug "Existing CNAME record found for ${CF_RECORD_NAME}: ${existing_content} (proxied=${existing_proxied})"

    if [[ "$existing_content" == "$CF_TUNNEL_CNAME" && "$existing_proxied" == "true" ]]; then
      log "Route already exists: ${CF_RECORD_NAME}"
      registry_write "$(registry_track "$CF_ZONE_ID" "$CF_RECORD_NAME" "$CF_TUNNEL_CNAME")"
      return
    fi

    payload="$(jq -n --arg type "CNAME" --arg name "$CF_RECORD_NAME" --arg content "$CF_TUNNEL_CNAME" '{type:$type,name:$name,content:$content,proxied:true}')"
    debug "Updating CNAME record for ${CF_RECORD_NAME} -> ${CF_TUNNEL_CNAME}"
    if ! response="$(api_request PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" "$payload")"; then
      debug "Failed to update CNAME record for ${CF_RECORD_NAME} -> ${CF_TUNNEL_CNAME}"
      exit 1
    fi
    assert_cf_success "$response" "update"
    log "Route updated: ${CF_RECORD_NAME} -> ${CF_TUNNEL_CNAME}"
    registry_write "$(registry_track "$CF_ZONE_ID" "$CF_RECORD_NAME" "$CF_TUNNEL_CNAME")"
  fi
}

# Disable: delete CNAME record
disable_route() {
  local record_json
  record_json="$(get_record_json)"
  debug "Existing CNAME record JSON for ${CF_RECORD_NAME}: ${record_json}"

  if [ -n "$record_json" ]; then
    local record_id existing_content allow_mismatch
    local response
    record_id="$(printf '%s' "$record_json" | jq -r '.id // empty')"
    existing_content="$(printf '%s' "$record_json" | jq -r '.content // empty')"
    allow_mismatch="${CF_ALLOW_DELETE_MISMATCH:-false}"

    if [[ "$existing_content" != "$CF_TUNNEL_CNAME" && "$allow_mismatch" != "true" ]]; then
      echo "Refusing to delete ${CF_RECORD_NAME}: existing target '${existing_content}' does not match CF_TUNNEL_CNAME '${CF_TUNNEL_CNAME}'." >&2
      echo "Set CF_ALLOW_DELETE_MISMATCH=true to override." >&2
      exit 1
    fi

    debug "Deleting CNAME record for ${CF_RECORD_NAME} -> ${existing_content}"
    if ! response="$(api_request DELETE "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}")"; then
      debug "Failed to delete CNAME record for ${CF_RECORD_NAME} -> ${existing_content}"
      exit 1
    fi
    assert_cf_success "$response" "delete"
    log "Route disabled: ${CF_RECORD_NAME}"
  else
    log "Route already removed: ${CF_RECORD_NAME}"
  fi
  registry_write "$(registry_untrack "$CF_ZONE_ID" "$CF_RECORD_NAME")"
}

status_route() {
  local response record_json
  response="$(lookup_records_response)"
  record_json="$(printf '%s' "$response" | jq -c --arg name "$CF_RECORD_NAME" 'first(.result[]? | select(.type == "CNAME" and .name == $name)) // empty')"

  if [[ "$VERBOSE" == "1" ]]; then
    debug "Full response: $response"
    printf '%s\n' "$response" | jq .
    return
  fi

  if [[ -z "$record_json" ]]; then
    if [[ "$QUIET" == "1" ]]; then
      echo "absent"
    else
      log "Status: absent (${CF_RECORD_NAME})"
    fi
    return
  fi

  local record_id existing_content existing_proxied state
  record_id="$(printf '%s' "$record_json" | jq -r '.id // empty')"
  existing_content="$(printf '%s' "$record_json" | jq -r '.content // empty')"
  existing_proxied="$(printf '%s' "$record_json" | jq -r '.proxied // false')"

  state="present"
  if [[ -n "${CF_TUNNEL_CNAME:-}" ]]; then
    if [[ "$existing_content" == "$CF_TUNNEL_CNAME" ]]; then
      state="active"
    else
      state="inactive"
    fi
  fi

  if [[ "$QUIET" == "1" ]]; then
    echo "$state"
    return
  fi

  if [[ -n "${CF_TUNNEL_CNAME:-}" && "$state" == "inactive" ]]; then
    log "Status: inactive (${CF_RECORD_NAME}) id=${record_id} content=${existing_content} expected=${CF_TUNNEL_CNAME} proxied=${existing_proxied}"
  else
    log "Status: ${state} (${CF_RECORD_NAME}) id=${record_id} content=${existing_content} proxied=${existing_proxied}"
  fi
}

# --- Tracked-route registry ---

registry_path() {
  local dir="${CF_TRACKED_ROUTES:-${XDG_STATE_HOME:-$HOME}/cf-dns-cname-route}"
  mkdir -p "$dir"
  printf '%s/.tracked_routes' "$dir"
}

registry_read() {
  local reg
  reg="$(registry_path)"
  [[ -f "$reg" ]] || return 0
  cat "$reg"
}

registry_write() {
  local reg content="$1"
  reg="$(registry_path)"
  if [[ -z "$content" ]]; then
    rm -f "$reg"
    return
  fi
  printf '%s\n' "$content" > "$reg"
}

registry_track() {
  local zone="$1" record="$2" target="$3"
  local line new_content
  line="$(printf '%s\t%s\t%s' "$zone" "$record" "$target")"
  new_content="$(registry_read | grep -Fv "$(printf '%s\t%s\t' "$zone" "$record")")"
  if [[ -n "$new_content" ]]; then
    printf '%s\n%s' "$new_content" "$line"
  else
    printf '%s' "$line"
  fi
}

registry_untrack() {
  local zone="$1" record="$2"
  registry_read | grep -Fv "$(printf '%s\t%s\t' "$zone" "$record")" | sed '/^$/d'
}

route_for_record() {
  local record="$1"
  registry_read | awk -F '\t' -v r="$record" '$2 == r { print; exit }'
}

# Disable (delete CF record) a tracked route and untrack it.
disable_tracked_route() {
  local record="$1" entry target zone
  entry="$(route_for_record "$record")"
  if [[ -z "$entry" ]]; then
    echo "Not a tracked route: ${record}" >&2
    exit 1
  fi
  zone="$(printf '%s' "$entry" | cut -f1)"
  target="$(printf '%s' "$entry" | cut -f3)"

  if [[ "$zone" != "$CF_ZONE_ID" ]]; then
    echo "Tracked route '${record}' is in zone ${zone}, not the loaded zone ${CF_ZONE_ID}." >&2
    echo "Load that zone's environment (e.g. --cf-env-file) then retry." >&2
    exit 1
  fi

  CF_RECORD_NAME="$record"
  CF_TUNNEL_CNAME="$target"
  disable_route
}

# List every tracked route, live status for the loaded zone.
list_routes() {
  local entries line z r t status
  local orig_quiet="$QUIET"
  entries="$(registry_read)"
  if [[ -z "$entries" ]]; then
    log "No tracked routes."
    return
  fi
  if [[ "$QUIET" != "1" ]]; then
    printf 'RECORD\tZONE\tTARGET\tSTATUS\n'
  fi

  while IFS=$'\t' read -r z r t; do
    [[ -n "$z" ]] || continue
    if [[ "$z" == "$CF_ZONE_ID" ]]; then
      QUIET=1
      status="$(status_route)"
      QUIET="$orig_quiet"
    else
      status="other-zone"
    fi
    printf '%s\t%s\t%s\t%s\n' "$r" "$z" "$t" "$status"
  done <<< "$entries"
}

parse_args() {
  command=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help)
        command="help"
        shift
        ;;
      -v|--verbose)
        VERBOSE=1
        shift
        ;;
      -q|--quiet|--quite)
        QUIET=1
        shift
        ;;
      -d|--debug)
        DEBUG=1
        shift
        ;;
      --cf-zone-id=*)
        OVERRIDE_CF_ZONE_ID="${1#*=}"
        shift
        ;;
      --cf-zone-id)
        OVERRIDE_CF_ZONE_ID="$(parse_opt_value "$1" "${2:-}")"
        shift 2
        ;;
      --cf-api-token=*)
        OVERRIDE_CF_API_TOKEN="${1#*=}"
        shift
        ;;
      --cf-api-token)
        OVERRIDE_CF_API_TOKEN="$(parse_opt_value "$1" "${2:-}")"
        shift 2
        ;;
      --cf-record-name=*)
        OVERRIDE_CF_RECORD_NAME="${1#*=}"
        shift
        ;;
      --cf-record-name)
        OVERRIDE_CF_RECORD_NAME="$(parse_opt_value "$1" "${2:-}")"
        shift 2
        ;;
      --cf-tunnel-cname=*)
        OVERRIDE_CF_TUNNEL_CNAME="${1#*=}"
        shift
        ;;
      --cf-tunnel-cname)
        OVERRIDE_CF_TUNNEL_CNAME="$(parse_opt_value "$1" "${2:-}")"
        shift 2
        ;;
      --cf-tunnel-id=*)
        OVERRIDE_CF_TUNNEL_ID="${1#*=}"
        shift
        ;;
      --cf-tunnel-id)
        OVERRIDE_CF_TUNNEL_ID="$(parse_opt_value "$1" "${2:-}")"
        shift 2
        ;;
      --cf-env-file=*)
        OVERRIDE_CF_ENV_FILE="${1#*=}"
        CF_ENV_FILE="$OVERRIDE_CF_ENV_FILE"
        shift
        ;;
      --cf-env-file)
        OVERRIDE_CF_ENV_FILE="$(parse_opt_value "$1" "${2:-}")"
        CF_ENV_FILE="$OVERRIDE_CF_ENV_FILE"
        shift 2
        ;;
      --cf-allow-delete-mismatch=*)
        OVERRIDE_CF_ALLOW_DELETE_MISMATCH="${1#*=}"
        shift
        ;;
      --cf-allow-delete-mismatch)
        OVERRIDE_CF_ALLOW_DELETE_MISMATCH="$(parse_opt_value "$1" "${2:-}")"
        shift 2
        ;;
      --cf-connect-timeout=*)
        OVERRIDE_CF_CONNECT_TIMEOUT="${1#*=}"
        shift
        ;;
      --cf-connect-timeout)
        OVERRIDE_CF_CONNECT_TIMEOUT="$(parse_opt_value "$1" "${2:-}")"
        shift 2
        ;;
      --cf-max-time=*)
        OVERRIDE_CF_MAX_TIME="${1#*=}"
        shift
        ;;
      --cf-max-time)
        OVERRIDE_CF_MAX_TIME="$(parse_opt_value "$1" "${2:-}")"
        shift 2
        ;;
      --cf-retry-count=*)
        OVERRIDE_CF_RETRY_COUNT="${1#*=}"
        shift
        ;;
      --cf-retry-count)
        OVERRIDE_CF_RETRY_COUNT="$(parse_opt_value "$1" "${2:-}")"
        shift 2
        ;;
      enable|disable|rid|status|routes|disable-route)
        if [[ -n "$command" ]]; then
          echo "Only one command can be provided." >&2
          print_usage
          exit 1
        fi
        if [[ "$1" == "disable-route" ]]; then
          command="disable-route"
          shift
          if [[ $# -eq 0 ]]; then
            echo "Missing record name for disable-route." >&2
            print_usage
            exit 1
          fi
          COMMAND_RECORD="$1"
        elif [[ "$1" == "routes" ]]; then
          command="routes"
        else
          command="$1"
        fi
        shift
        ;;
      *)
        echo "Unknown argument: $1" >&2
        print_usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$command" ]]; then
    print_usage
    exit 1
  fi

  if [[ "$QUIET" == "1" && "$VERBOSE" == "1" ]]; then
    echo "Options --quiet and --verbose cannot be used together." >&2
    exit 1
  fi
}

apply_overrides() {
  if [[ -n "$OVERRIDE_CF_ZONE_ID" ]]; then
    CF_ZONE_ID="$OVERRIDE_CF_ZONE_ID"
    debug "CF_ZONE_ID overridden to '$CF_ZONE_ID'"
  fi
  if [[ -n "$OVERRIDE_CF_API_TOKEN" ]]; then
    CF_API_TOKEN="$OVERRIDE_CF_API_TOKEN"
    debug "CF_API_TOKEN overridden"
  fi
  if [[ -n "$OVERRIDE_CF_RECORD_NAME" ]]; then
    CF_RECORD_NAME="$OVERRIDE_CF_RECORD_NAME"
    debug "CF_RECORD_NAME overridden to '$CF_RECORD_NAME'"
  fi
  if [[ -n "$OVERRIDE_CF_TUNNEL_CNAME" ]]; then
    CF_TUNNEL_CNAME="$OVERRIDE_CF_TUNNEL_CNAME"
    debug "CF_TUNNEL_CNAME overridden to '$CF_TUNNEL_CNAME'"
  fi
  if [[ -n "$OVERRIDE_CF_TUNNEL_ID" ]]; then
    CF_TUNNEL_ID="$OVERRIDE_CF_TUNNEL_ID"
    debug "CF_TUNNEL_ID overridden to '$CF_TUNNEL_ID'"

    if [[ -z "$OVERRIDE_CF_TUNNEL_CNAME" ]]; then
      CF_TUNNEL_CNAME="${CF_TUNNEL_ID}${CF_TUNNEL_CNAME_SUFFIX}"
      debug "CF_TUNNEL_CNAME derived from overridden CF_TUNNEL_ID as '$CF_TUNNEL_CNAME'"
    fi
  fi
  if [[ -n "$OVERRIDE_CF_ENV_FILE" ]]; then
    CF_ENV_FILE="$OVERRIDE_CF_ENV_FILE"
    debug "CF_ENV_FILE overridden to '$CF_ENV_FILE'"
  fi
  if [[ -n "$OVERRIDE_CF_ALLOW_DELETE_MISMATCH" ]]; then
    CF_ALLOW_DELETE_MISMATCH="$OVERRIDE_CF_ALLOW_DELETE_MISMATCH"
    debug "CF_ALLOW_DELETE_MISMATCH overridden to '$CF_ALLOW_DELETE_MISMATCH'"
  fi
  if [[ -n "$OVERRIDE_CF_CONNECT_TIMEOUT" ]]; then
    CF_CONNECT_TIMEOUT="$OVERRIDE_CF_CONNECT_TIMEOUT"
    debug "CF_CONNECT_TIMEOUT overridden to '$CF_CONNECT_TIMEOUT'"
  fi
  if [[ -n "$OVERRIDE_CF_MAX_TIME" ]]; then
    CF_MAX_TIME="$OVERRIDE_CF_MAX_TIME"
    debug "CF_MAX_TIME overridden to '$CF_MAX_TIME'"
  fi
  if [[ -n "$OVERRIDE_CF_RETRY_COUNT" ]]; then
    CF_RETRY_COUNT="$OVERRIDE_CF_RETRY_COUNT"
    debug "CF_RETRY_COUNT overridden to '$CF_RETRY_COUNT'"
  fi
}

parse_args "$@"
debug "parsed args command=${command} quiet=${QUIET} verbose=${VERBOSE} debug=${DEBUG}"

case "$command" in
  help)
    print_help
    exit 0
    ;;
  enable|disable|rid|status|routes|disable-route)
    ;;
  *)
    print_usage
    exit 1
    ;;
esac

load_env
debug "environment loaded from CF_ENV_FILE='${CF_ENV_FILE:-auto-discovery}'"
apply_overrides
debug "overrides applied zone_set=$([[ -n "${CF_ZONE_ID:-}" ]] && echo yes || echo no) record='${CF_RECORD_NAME:-}' tunnel_cname_set=$([[ -n "${CF_TUNNEL_CNAME:-}" ]] && echo yes || echo no)"

require_command curl
require_command jq
debug "required commands are available"

if [ -z "${CF_TUNNEL_CNAME:-}" ] && [ -n "${CF_TUNNEL_ID:-}" ]; then
  CF_TUNNEL_CNAME="${CF_TUNNEL_ID}${CF_TUNNEL_CNAME_SUFFIX}"
  debug "derived CF_TUNNEL_CNAME from CF_TUNNEL_ID"
fi

require_env CF_ZONE_ID
require_env CF_API_TOKEN

case "$command" in
  enable|disable|rid|status)
    require_env CF_RECORD_NAME
    ;;
esac

if [[ "$command" == "enable" || "$command" == "disable" ]]; then
  require_env CF_TUNNEL_CNAME
fi

debug "environment validation completed"

case "$command" in
  enable)
    enable_route
    ;;
  disable)
    disable_route
    ;;
  rid)
    get_record_id
    ;;
  status)
    status_route
    ;;
  routes)
    list_routes
    ;;
  disable-route)
    disable_tracked_route "$COMMAND_RECORD"
    ;;
esac
