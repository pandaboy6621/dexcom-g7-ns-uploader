#!/usr/bin/env bash
#
# dexcom-ns-uploader.sh
#
# Pulls glucose readings from Dexcom Share (the same cloud the Dexcom G7 app
# uploads to, and that pydexcom / Home Assistant / xDrip "Dex Share follower"
# read from) and uploads them to Nightscout as SGV entries.
#
# Requirements: bash, curl, jq, and sha1sum or shasum.
#
# Usage:
#   ./dexcom-ns-uploader.sh            # loop forever, polling every POLL_INTERVAL seconds
#   ./dexcom-ns-uploader.sh --once     # one sync, then exit (for cron / n8n / timers)
#   ./dexcom-ns-uploader.sh --check    # log in to Dexcom + Nightscout, print latest reading, upload nothing
#
# Configuration is read from environment variables, or from a .env file
# (default: .env next to this script, override with ENV_FILE=/path/to/file).
# See .env.example.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

DEXCOM_USERNAME="${DEXCOM_USERNAME:-}"
DEXCOM_PASSWORD="${DEXCOM_PASSWORD:-}"
DEXCOM_REGION="$(printf '%s' "${DEXCOM_REGION:-us}" | tr '[:upper:]' '[:lower:]')"
NIGHTSCOUT_URL="${NIGHTSCOUT_URL:-}"
NIGHTSCOUT_API_SECRET="${NIGHTSCOUT_API_SECRET:-}"
NIGHTSCOUT_TOKEN="${NIGHTSCOUT_TOKEN:-}"
POLL_INTERVAL="${POLL_INTERVAL:-120}"
BACKFILL_MINUTES="${BACKFILL_MINUTES:-1440}"
DEVICE_NAME="${DEVICE_NAME:-dexcom-g7-ns-uploader}"
LOG_LEVEL="$(printf '%s' "${LOG_LEVEL:-info}" | tr '[:upper:]' '[:lower:]')"

# ---------------------------------------------------------------- logging ---

log()   { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >&2; }
info()  { log INFO "$*"; }
warn()  { log WARN "$*"; }
error() { log ERROR "$*"; }
debug() { [ "$LOG_LEVEL" = "debug" ] && log DEBUG "$*"; return 0; }
die()   { error "$*"; exit 1; }

# ----------------------------------------------------------------- config ---

case "$DEXCOM_REGION" in
  us)  DEFAULT_BASE="https://share2.dexcom.com/ShareWebServices/Services"
       APPLICATION_ID="d89443d2-327c-4a6f-89e5-496bbb0317db" ;;
  ous) DEFAULT_BASE="https://shareous1.dexcom.com/ShareWebServices/Services"
       APPLICATION_ID="d89443d2-327c-4a6f-89e5-496bbb0317db" ;;
  jp)  DEFAULT_BASE="https://share.dexcom.jp/ShareWebServices/Services"
       APPLICATION_ID="d8665ade-9673-4e27-9ff6-92db4ce13d13" ;;
  *)   die "DEXCOM_REGION must be one of: us, ous, jp (got '$DEXCOM_REGION')" ;;
esac
DEXCOM_BASE_URL="${DEXCOM_BASE_URL:-$DEFAULT_BASE}"
NIGHTSCOUT_URL="${NIGHTSCOUT_URL%/}"

NULL_UUID="00000000-0000-0000-0000-000000000000"
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

check_config() {
  local missing=""
  for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
  done
  [ -n "$missing" ] && die "missing required command(s):$missing"
  [ -n "$DEXCOM_USERNAME" ] || die "DEXCOM_USERNAME is not set"
  [ -n "$DEXCOM_PASSWORD" ] || die "DEXCOM_PASSWORD is not set"
  [ -n "$NIGHTSCOUT_URL" ]  || die "NIGHTSCOUT_URL is not set"
  [ -n "$NIGHTSCOUT_API_SECRET$NIGHTSCOUT_TOKEN" ] \
    || die "set NIGHTSCOUT_API_SECRET or NIGHTSCOUT_TOKEN"
  case "$POLL_INTERVAL" in ''|*[!0-9]*) die "POLL_INTERVAL must be a whole number of seconds";; esac
  case "$BACKFILL_MINUTES" in ''|*[!0-9]*) die "BACKFILL_MINUTES must be a whole number";; esac
  [ "$BACKFILL_MINUTES" -gt 1440 ] && BACKFILL_MINUTES=1440
  [ "$BACKFILL_MINUTES" -lt 1 ] && BACKFILL_MINUTES=1
  return 0
}

sha1() {
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1
  fi
}

# Nightscout expects the SHA-1 of API_SECRET in the api-secret header.
# If the value already looks like a SHA-1 hash, use it as-is.
NS_SECRET_HASH=""
if [ -n "$NIGHTSCOUT_API_SECRET" ]; then
  if printf '%s' "$NIGHTSCOUT_API_SECRET" | grep -Eq '^[0-9a-fA-F]{40}$'; then
    NS_SECRET_HASH="$(printf '%s' "$NIGHTSCOUT_API_SECRET" | tr '[:upper:]' '[:lower:]')"
  else
    NS_SECRET_HASH="$(sha1 "$NIGHTSCOUT_API_SECRET")"
  fi
fi

# ------------------------------------------------------------------- http ---

# http METHOD URL [JSON_BODY] [extra curl args...]
# Sets HTTP_CODE and HTTP_BODY. Returns non-zero on network failure only.
HTTP_CODE=""
HTTP_BODY=""
http() {
  local method="$1" url="$2" body="${3:-}" out
  shift 3 2>/dev/null || shift $#
  out="$(curl -sS --max-time 30 -X "$method" \
          -H 'Content-Type: application/json' -H 'Accept: application/json' \
          -H "User-Agent: $DEVICE_NAME" \
          --data "$body" -w '\n%{http_code}' "$@" "$url" 2>&1)"
  local rc=$?
  HTTP_CODE="${out##*$'\n'}"
  HTTP_BODY="${out%$'\n'*}"
  if [ $rc -ne 0 ]; then
    HTTP_CODE="000"
    HTTP_BODY="$out"
    return 1
  fi
  return 0
}

# Nightscout auth: header for API_SECRET, query param for access token.
ns_url() {
  local path="$1" sep="?"
  case "$path" in *\?*) sep="&";; esac
  if [ -n "$NIGHTSCOUT_TOKEN" ]; then
    printf '%s%s%stoken=%s' "$NIGHTSCOUT_URL" "$path" "$sep" "$NIGHTSCOUT_TOKEN"
  else
    printf '%s%s' "$NIGHTSCOUT_URL" "$path"
  fi
}
ns_http() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$NS_SECRET_HASH" ]; then
    http "$method" "$(ns_url "$path")" "$body" -H "api-secret: $NS_SECRET_HASH"
  else
    http "$method" "$(ns_url "$path")" "$body"
  fi
}

# ----------------------------------------------------------------- dexcom ---

SESSION_ID=""

dexcom_error_code() { printf '%s' "$HTTP_BODY" | jq -r '.Code // empty' 2>/dev/null; }

dexcom_post_uuid() {
  # POSTs and expects a JSON string containing a UUID back.
  local endpoint="$1" body="$2" value
  http POST "$DEXCOM_BASE_URL/$endpoint" "$body" || { error "Dexcom $endpoint: network error: $HTTP_BODY"; return 1; }
  if [ "$HTTP_CODE" != "200" ]; then
    error "Dexcom $endpoint failed (HTTP $HTTP_CODE): $(dexcom_error_code) $(printf '%s' "$HTTP_BODY" | jq -r '.Message // empty' 2>/dev/null)"
    return 1
  fi
  value="$(printf '%s' "$HTTP_BODY" | jq -r '. // empty' 2>/dev/null)"
  if ! printf '%s' "$value" | grep -Eq "$UUID_RE" || [ "$value" = "$NULL_UUID" ]; then
    error "Dexcom $endpoint returned an invalid id (check username/password/region)"
    return 1
  fi
  printf '%s' "$value"
}

dexcom_login() {
  local account_id body
  if printf '%s' "$DEXCOM_USERNAME" | grep -Eq "$UUID_RE"; then
    account_id="$DEXCOM_USERNAME"
  else
    body="$(jq -nc --arg u "$DEXCOM_USERNAME" --arg p "$DEXCOM_PASSWORD" --arg a "$APPLICATION_ID" \
            '{accountName:$u, password:$p, applicationId:$a}')"
    account_id="$(dexcom_post_uuid General/AuthenticatePublisherAccount "$body")" || return 1
  fi
  debug "Dexcom account id: $account_id"
  body="$(jq -nc --arg i "$account_id" --arg p "$DEXCOM_PASSWORD" --arg a "$APPLICATION_ID" \
          '{accountId:$i, password:$p, applicationId:$a}')"
  SESSION_ID="$(dexcom_post_uuid General/LoginPublisherAccountById "$body")" || { SESSION_ID=""; return 1; }
  info "Logged in to Dexcom Share ($DEXCOM_REGION)"
}

# dexcom_readings MINUTES MAXCOUNT -> raw JSON array on stdout
dexcom_readings() {
  local minutes="$1" max="$2" attempt
  for attempt in 1 2; do
    if [ -z "$SESSION_ID" ]; then dexcom_login || return 1; fi
    http POST "$DEXCOM_BASE_URL/Publisher/ReadPublisherLatestGlucoseValues?sessionId=$SESSION_ID&minutes=$minutes&maxCount=$max" "" \
      || { error "Dexcom readings: network error: $HTTP_BODY"; return 1; }
    if [ "$HTTP_CODE" = "200" ]; then
      printf '%s' "$HTTP_BODY"
      return 0
    fi
    case "$(dexcom_error_code)" in
      SessionNotValid|SessionIdNotFound)
        info "Dexcom session expired, logging in again"
        SESSION_ID="" ;;
      *)
        error "Dexcom readings failed (HTTP $HTTP_CODE): $HTTP_BODY"
        SESSION_ID=""
        return 1 ;;
    esac
  done
  return 1
}

# Converts Dexcom Share readings into Nightscout entries newer than SINCE_MS.
to_nightscout() {
  jq -c --argjson since "$1" --arg dev "$DEVICE_NAME" '
    def trend_name:
      if type == "number" then
        (["None","DoubleUp","SingleUp","FortyFiveUp","Flat","FortyFiveDown",
          "SingleDown","DoubleDown","NotComputable","RateOutOfRange"][.] // "None")
      else (. // "None" | tostring) end;
    def ns_direction:
      {"None":"NONE","NotComputable":"NOT COMPUTABLE","RateOutOfRange":"RATE OUT OF RANGE"}[.] // .;
    [ .[]
      | ((.WT // .ST) | capture("(?<ms>-?[0-9]+)").ms | tonumber) as $ms
      | select($ms > $since and (.Value | type) == "number" and .Value > 0)
      | { type: "sgv",
          sgv: .Value,
          date: $ms,
          dateString: ($ms / 1000 | floor | todate),
          direction: (.Trend | trend_name | ns_direction),
          device: $dev } ]
    | unique_by(.date) | sort_by(.date)'
}

# ------------------------------------------------------------- nightscout ---

# Prints the timestamp (ms) of the newest SGV entry in Nightscout, or 0.
ns_last_entry_ms() {
  ns_http GET "/api/v1/entries/sgv.json?count=1" "" || { error "Nightscout: network error: $HTTP_BODY"; return 1; }
  case "$HTTP_CODE" in
    200) printf '%s' "$HTTP_BODY" | jq -r '(.[0].date // 0) | floor' 2>/dev/null || printf '0' ;;
    401|403) error "Nightscout rejected the credentials (HTTP $HTTP_CODE). Check NIGHTSCOUT_API_SECRET / NIGHTSCOUT_TOKEN"; return 1 ;;
    *) error "Nightscout read failed (HTTP $HTTP_CODE): $HTTP_BODY"; return 1 ;;
  esac
}

ns_upload() {
  ns_http POST "/api/v1/entries" "$1" || { error "Nightscout upload: network error: $HTTP_BODY"; return 1; }
  case "$HTTP_CODE" in
    200|201) return 0 ;;
    401|403) error "Nightscout rejected the upload (HTTP $HTTP_CODE). The token needs a role with api:entries:create (or use the API secret)"; return 1 ;;
    *) error "Nightscout upload failed (HTTP $HTTP_CODE): $HTTP_BODY"; return 1 ;;
  esac
}

# ------------------------------------------------------------------- sync ---

now_ms() { printf '%s000' "$(date +%s)"; }

sync_once() {
  local dry_run="${1:-0}" last_ms minutes raw entries count newest
  last_ms="$(ns_last_entry_ms)" || return 1
  debug "newest Nightscout SGV: $last_ms"

  # Only ask Dexcom for the gap since the last Nightscout entry (plus margin).
  if [ "$last_ms" -gt 0 ]; then
    minutes=$(( ( $(now_ms) - last_ms ) / 60000 + 10 ))
    [ "$minutes" -gt "$BACKFILL_MINUTES" ] && minutes="$BACKFILL_MINUTES"
    [ "$minutes" -lt 10 ] && minutes=10
  else
    minutes="$BACKFILL_MINUTES"
  fi

  raw="$(dexcom_readings "$minutes" 288)" || return 1
  entries="$(printf '%s' "$raw" | to_nightscout "$last_ms")" || { error "could not parse Dexcom response: $raw"; return 1; }
  count="$(printf '%s' "$entries" | jq 'length')"

  if [ "$dry_run" = "1" ]; then
    info "Nightscout OK. Newest Nightscout SGV: $( [ "$last_ms" -gt 0 ] && date -r $((last_ms/1000)) 2>/dev/null || date -d @$((last_ms/1000)) 2>/dev/null || echo none)"
    info "Dexcom OK. $(printf '%s' "$raw" | jq 'length') reading(s) in the last $minutes min; latest: $(printf '%s' "$raw" | to_nightscout 0 | jq -r 'last | if . then "\(.sgv) mg/dL \(.direction) at \(.dateString)" else "none" end')"
    info "Would upload $count new reading(s). Nothing was uploaded (--check)."
    return 0
  fi

  if [ "$count" -eq 0 ]; then
    debug "no new readings"
    return 0
  fi

  ns_upload "$entries" || return 1
  newest="$(printf '%s' "$entries" | jq -r 'last | "\(.sgv) mg/dL \(.direction) at \(.dateString)"')"
  info "Uploaded $count reading(s) to Nightscout, newest: $newest"
}

main() {
  local mode="loop"
  case "${1:-}" in
    --once)  mode="once" ;;
    --check) mode="check" ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) die "unknown option: $1 (use --once, --check or --help)" ;;
  esac

  check_config

  case "$mode" in
    once)  sync_once; exit $? ;;
    check) sync_once 1; exit $? ;;
  esac

  [ "$POLL_INTERVAL" -lt 60 ] && { warn "POLL_INTERVAL below 60s; using 60s"; POLL_INTERVAL=60; }
  info "Starting: Dexcom Share ($DEXCOM_REGION) -> $NIGHTSCOUT_URL every ${POLL_INTERVAL}s"
  trap 'info "Stopping"; exit 0' INT TERM

  local failures=0 delay
  while :; do
    if sync_once; then
      failures=0
      delay="$POLL_INTERVAL"
    else
      failures=$((failures + 1))
      # Back off on repeated failures (max 30 min) so a bad password
      # doesn't hammer Dexcom and get the account locked.
      delay=$(( 60 * (1 << (failures < 5 ? failures : 5)) ))
      [ "$delay" -gt 1800 ] && delay=1800
      warn "sync failed ($failures in a row), retrying in ${delay}s"
    fi
    sleep "$delay" &
    wait $!
  done
}

main "$@"
