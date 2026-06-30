#!/usr/bin/env bash
# tunnel_route.sh — enable/disable Cloudflare DNS record for tunnel routing.

set -euo pipefail

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
  enable     Create the Cloudflare CNAME route if it does not exist.
  disable    Delete the Cloudflare CNAME route if it exists.
  rid        Print the Cloudflare DNS record ID for CF_RECORD_NAME.
  status     Show status of the Cloudflare CNAME record.
  help       Show this help message.

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
EOF
}

print_usage() {
  echo "Usage: $0 [options] {enable|disable|rid|status|help}" >&2
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
    if ! response="$(api_request POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" "$payload")"; then
      exit 1
    fi
    assert_cf_success "$response" "create"
    log "Route enabled: ${CF_RECORD_NAME} -> ${CF_TUNNEL_CNAME}"
  else
    local record_id existing_content existing_proxied
    local payload response
    record_id="$(printf '%s' "$record_json" | jq -r '.id // empty')"
    existing_content="$(printf '%s' "$record_json" | jq -r '.content // empty')"
    existing_proxied="$(printf '%s' "$record_json" | jq -r '.proxied // false')"

    if [[ "$existing_content" == "$CF_TUNNEL_CNAME" && "$existing_proxied" == "true" ]]; then
      log "Route already exists: ${CF_RECORD_NAME}"
      return
    fi

    payload="$(jq -n --arg type "CNAME" --arg name "$CF_RECORD_NAME" --arg content "$CF_TUNNEL_CNAME" '{type:$type,name:$name,content:$content,proxied:true}')"
    if ! response="$(api_request PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" "$payload")"; then
      exit 1
    fi
    assert_cf_success "$response" "update"
    log "Route updated: ${CF_RECORD_NAME} -> ${CF_TUNNEL_CNAME}"
  fi
}

# Disable: delete CNAME record
disable_route() {
  local record_json
  record_json="$(get_record_json)"

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

    if ! response="$(api_request DELETE "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}")"; then
      exit 1
    fi
    assert_cf_success "$response" "delete"
    log "Route disabled: ${CF_RECORD_NAME}"
  else
    log "Route already removed: ${CF_RECORD_NAME}"
  fi
}

status_route() {
  local response record_json
  response="$(lookup_records_response)"
  record_json="$(printf '%s' "$response" | jq -c --arg name "$CF_RECORD_NAME" 'first(.result[]? | select(.type == "CNAME" and .name == $name)) // empty')"

  if [[ "$VERBOSE" == "1" ]]; then
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
      state="match"
    else
      state="mismatch"
    fi
  fi

  if [[ "$QUIET" == "1" ]]; then
    echo "$state"
    return
  fi

  if [[ -n "${CF_TUNNEL_CNAME:-}" && "$state" == "mismatch" ]]; then
    log "Status: mismatch (${CF_RECORD_NAME}) id=${record_id} content=${existing_content} expected=${CF_TUNNEL_CNAME} proxied=${existing_proxied}"
  else
    log "Status: ${state} (${CF_RECORD_NAME}) id=${record_id} content=${existing_content} proxied=${existing_proxied}"
  fi
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
      enable|disable|rid|status)
        if [[ -n "$command" ]]; then
          echo "Only one command can be provided." >&2
          print_usage
          exit 1
        fi
        command="$1"
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
  fi
  if [[ -n "$OVERRIDE_CF_API_TOKEN" ]]; then
    CF_API_TOKEN="$OVERRIDE_CF_API_TOKEN"
  fi
  if [[ -n "$OVERRIDE_CF_RECORD_NAME" ]]; then
    CF_RECORD_NAME="$OVERRIDE_CF_RECORD_NAME"
  fi
  if [[ -n "$OVERRIDE_CF_TUNNEL_CNAME" ]]; then
    CF_TUNNEL_CNAME="$OVERRIDE_CF_TUNNEL_CNAME"
  fi
  if [[ -n "$OVERRIDE_CF_TUNNEL_ID" ]]; then
    CF_TUNNEL_ID="$OVERRIDE_CF_TUNNEL_ID"
  fi
  if [[ -n "$OVERRIDE_CF_ENV_FILE" ]]; then
    CF_ENV_FILE="$OVERRIDE_CF_ENV_FILE"
  fi
  if [[ -n "$OVERRIDE_CF_ALLOW_DELETE_MISMATCH" ]]; then
    CF_ALLOW_DELETE_MISMATCH="$OVERRIDE_CF_ALLOW_DELETE_MISMATCH"
  fi
  if [[ -n "$OVERRIDE_CF_CONNECT_TIMEOUT" ]]; then
    CF_CONNECT_TIMEOUT="$OVERRIDE_CF_CONNECT_TIMEOUT"
  fi
  if [[ -n "$OVERRIDE_CF_MAX_TIME" ]]; then
    CF_MAX_TIME="$OVERRIDE_CF_MAX_TIME"
  fi
  if [[ -n "$OVERRIDE_CF_RETRY_COUNT" ]]; then
    CF_RETRY_COUNT="$OVERRIDE_CF_RETRY_COUNT"
  fi
}

parse_args "$@"
debug "parsed args command=${command} quiet=${QUIET} verbose=${VERBOSE} debug=${DEBUG}"

case "$command" in
  help)
    print_help
    exit 0
    ;;
  enable|disable|rid|status)
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
  CF_TUNNEL_CNAME="${CF_TUNNEL_ID}.cfargotunnel.com"
  debug "derived CF_TUNNEL_CNAME from CF_TUNNEL_ID"
fi

require_env CF_ZONE_ID
require_env CF_API_TOKEN
require_env CF_RECORD_NAME

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
esac
