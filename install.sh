#!/usr/bin/env bash
#
# install.sh - interactive setup for dexcom-ns-uploader
#
#   ./install.sh              set up .env, test the connection, start it in the background
#   ./install.sh --uninstall  stop and remove the background service
#
# Works on Linux (systemd), macOS (launchd) or anywhere with Docker.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPLOADER="$REPO_DIR/dexcom-ns-uploader.sh"
ENV_FILE="$REPO_DIR/.env"

SERVICE_NAME="dexcom-ns-uploader"
SYSTEMD_DIR="/opt/dexcom-g7-ns-uploader"
SYSTEMD_ENV="/etc/dexcom-ns-uploader.env"
SYSTEMD_UNIT="/etc/systemd/system/$SERVICE_NAME.service"
LAUNCHD_LABEL="net.dexcom-ns-uploader"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
LAUNCHD_LOG="$HOME/Library/Logs/dexcom-ns-uploader.log"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$*"; }
fail()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

ask() {   # ask VAR "Prompt" [default]
  local __var="$1" __prompt="$2" __default="${3:-}" __reply
  if [ -n "$__default" ]; then
    printf '%s [%s]: ' "$__prompt" "$__default"
  else
    printf '%s: ' "$__prompt"
  fi
  IFS= read -r __reply || __reply=""
  [ -z "$__reply" ] && __reply="$__default"
  printf -v "$__var" '%s' "$__reply"
}

ask_secret() {   # ask_secret VAR "Prompt"
  local __var="$1" __prompt="$2" __reply
  printf '%s (typing is hidden): ' "$__prompt"
  if [ -t 0 ]; then stty -echo; fi
  IFS= read -r __reply || __reply=""
  if [ -t 0 ]; then stty echo; fi
  printf '\n'
  printf -v "$__var" '%s' "$__reply"
}

yes_no() {   # yes_no "Question" default(y|n)
  local reply def="${2:-y}"
  printf '%s [%s]: ' "$1" "$( [ "$def" = y ] && echo Y/n || echo y/N )"
  IFS= read -r reply || reply=""
  [ -z "$reply" ] && reply="$def"
  case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)  echo linux ;;
    *)      echo other ;;
  esac
}

# --------------------------------------------------------------- uninstall ---

uninstall() {
  bold "Removing background service"
  if [ -f "$LAUNCHD_PLIST" ]; then
    launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || launchctl unload "$LAUNCHD_PLIST" 2>/dev/null
    rm -f "$LAUNCHD_PLIST"
    ok "Removed launchd agent"
  fi
  if [ -f "$SYSTEMD_UNIT" ]; then
    sudo systemctl disable --now "$SERVICE_NAME" 2>/dev/null
    sudo rm -f "$SYSTEMD_UNIT" "$SYSTEMD_ENV"
    sudo rm -rf "$SYSTEMD_DIR"
    sudo systemctl daemon-reload
    ok "Removed systemd service"
  fi
  if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$SERVICE_NAME"; then
    (cd "$REPO_DIR" && docker compose down)
    ok "Stopped Docker container"
  fi
  ok "Done. Your settings are still in $ENV_FILE (delete it if you no longer need it)."
  exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ -f "$UPLOADER" ] || fail "can't find dexcom-ns-uploader.sh next to install.sh"
chmod +x "$UPLOADER"

# ------------------------------------------------------------ dependencies ---

bold "1/4  Checking requirements"
missing=""
for cmd in curl jq; do command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"; done
if [ -n "$missing" ]; then
  warn "Missing:$missing"
  installer=""
  if command -v brew >/dev/null 2>&1; then installer="brew install"
  elif command -v apt-get >/dev/null 2>&1; then installer="sudo apt-get install -y"
  elif command -v dnf >/dev/null 2>&1; then installer="sudo dnf install -y"
  elif command -v apk >/dev/null 2>&1; then installer="sudo apk add"
  elif command -v pacman >/dev/null 2>&1; then installer="sudo pacman -S --noconfirm"
  fi
  [ -n "$installer" ] || fail "install$missing with your package manager, then run this again"
  if yes_no "Install them now with '$installer$missing'?" y; then
    # shellcheck disable=SC2086
    $installer $missing || fail "install failed"
  else
    fail "install$missing, then run this again"
  fi
fi
ok "curl and jq are installed"

# ------------------------------------------------------------------ config ---

env_value() {   # quote a value for .env; works for bash, systemd and docker compose
  case "$1" in
    *"'"*|*$'\n'*) fail "values can't contain a single quote or newline. Edit $ENV_FILE by hand instead." ;;
  esac
  printf "'%s'" "$1"
}

write_env() {
  local old_umask
  old_umask="$(umask)"
  umask 077
  {
    echo "# Created by install.sh on $(date '+%Y-%m-%d'). Keep this file private."
    echo "DEXCOM_USERNAME=$(env_value "$DEXCOM_USERNAME")"
    echo "DEXCOM_PASSWORD=$(env_value "$DEXCOM_PASSWORD")"
    echo "DEXCOM_REGION=$(env_value "$DEXCOM_REGION")"
    echo "NIGHTSCOUT_URL=$(env_value "$NIGHTSCOUT_URL")"
    if [ -n "$NIGHTSCOUT_TOKEN" ]; then
      echo "NIGHTSCOUT_TOKEN=$(env_value "$NIGHTSCOUT_TOKEN")"
    else
      echo "NIGHTSCOUT_API_SECRET=$(env_value "$NIGHTSCOUT_API_SECRET")"
    fi
    echo "POLL_INTERVAL=120"
    echo "BACKFILL_MINUTES=1440"
    echo "DEVICE_NAME='dexcom-g7-ns-uploader'"
    echo "LOG_LEVEL='info'"
  } > "$ENV_FILE"
  umask "$old_umask"
  chmod 600 "$ENV_FILE"
}

collect_config() {
  echo
  echo "Use the Dexcom account of the person wearing the G7 (the account that shares, not a follower)."
  while :; do
    ask DEXCOM_USERNAME "Dexcom username (email, or phone with + and country code, e.g. +15551234567)" "${DEXCOM_USERNAME:-}"
    case "$DEXCOM_USERNAME" in
      "") warn "required" ;;
      +*|*@*|????????-????-????-????-????????????) break ;;
      [0-9]*) warn "phone numbers need + and the country code, e.g. +1 for the US: +1${DEXCOM_USERNAME}"
              DEXCOM_USERNAME="" ;;
      *) break ;;
    esac
  done
  while :; do
    ask_secret DEXCOM_PASSWORD "Dexcom password"
    [ -n "$DEXCOM_PASSWORD" ] && break
    warn "required"
  done
  while :; do
    ask DEXCOM_REGION "Region: us, ous (outside the US) or jp" "${DEXCOM_REGION:-us}"
    DEXCOM_REGION="$(printf '%s' "$DEXCOM_REGION" | tr '[:upper:]' '[:lower:]')"
    case "$DEXCOM_REGION" in us|ous|jp) break ;; *) warn "type us, ous or jp" ;; esac
  done
  echo
  while :; do
    ask NIGHTSCOUT_URL "Nightscout URL (e.g. https://nightscout.example.com)" "${NIGHTSCOUT_URL:-}"
    NIGHTSCOUT_URL="${NIGHTSCOUT_URL%/}"
    case "$NIGHTSCOUT_URL" in http://*|https://*) break ;; "") warn "required" ;; *) NIGHTSCOUT_URL="https://$NIGHTSCOUT_URL"; break ;; esac
  done
  echo "Nightscout login: 1) API_SECRET   2) access token (needs readable + a role with api:entries:create; see README)"
  ask ns_auth "Choose 1 or 2" "1"
  NIGHTSCOUT_TOKEN=""
  NIGHTSCOUT_API_SECRET=""
  if [ "$ns_auth" = "2" ]; then
    while [ -z "$NIGHTSCOUT_TOKEN" ]; do ask_secret NIGHTSCOUT_TOKEN "Nightscout access token"; done
  else
    while [ -z "$NIGHTSCOUT_API_SECRET" ]; do ask_secret NIGHTSCOUT_API_SECRET "Nightscout API_SECRET"; done
  fi
}

bold "2/4  Settings"
if [ -f "$ENV_FILE" ] && yes_no "Found existing settings in .env. Keep them?" y; then
  ok "Using existing .env"
else
  collect_config
  write_env
  ok "Saved settings to .env (only you can read it)"
fi

# ------------------------------------------------------------------- check ---

bold "3/4  Testing Dexcom and Nightscout (nothing is uploaded)"
while ! ENV_FILE="$ENV_FILE" "$UPLOADER" --check; do
  echo
  warn "The test failed. The message above says which login failed."
  yes_no "Re-enter your settings and try again?" y || fail "fix .env and run ./install.sh again"
  set -a; . "$ENV_FILE"; set +a
  collect_config
  write_env
done
ok "Both logins work"

# ----------------------------------------------------------------- service ---

install_systemd() {
  command -v systemctl >/dev/null 2>&1 || fail "systemd not found; choose Docker or run it manually"
  echo "This needs sudo to install into $SYSTEMD_DIR and /etc."
  sudo install -Dm755 "$UPLOADER" "$SYSTEMD_DIR/dexcom-ns-uploader.sh" || fail "install failed"
  sudo install -Dm600 "$ENV_FILE" "$SYSTEMD_ENV" || fail "install failed"
  sudo install -Dm644 "$REPO_DIR/dexcom-ns-uploader.service" "$SYSTEMD_UNIT" || fail "install failed"
  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  sudo systemctl restart "$SERVICE_NAME" || fail "service failed to start; see: journalctl -u $SERVICE_NAME"
  ok "Running as a systemd service (starts on boot)"
  echo "   Logs:      journalctl -u $SERVICE_NAME -f"
  echo "   Stop:      sudo systemctl stop $SERVICE_NAME"
  echo "   Settings:  $SYSTEMD_ENV (edit, then: sudo systemctl restart $SERVICE_NAME)"
}

install_launchd() {
  mkdir -p "$(dirname "$LAUNCHD_PLIST")" "$(dirname "$LAUNCHD_LOG")"
  cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$UPLOADER</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ENV_FILE</key><string>$ENV_FILE</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$LAUNCHD_LOG</string>
  <key>StandardErrorPath</key><string>$LAUNCHD_LOG</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_PLIST" 2>/dev/null || launchctl load "$LAUNCHD_PLIST" \
    || fail "launchctl couldn't load $LAUNCHD_PLIST"
  ok "Running in the background (starts when you log in)"
  echo "   Logs:      tail -f $LAUNCHD_LOG"
  echo "   Settings:  $ENV_FILE (edit, then run ./install.sh again)"
  warn "It only runs while this Mac is on and awake. For 24/7 use a Linux box or Docker."
}

install_docker() {
  command -v docker >/dev/null 2>&1 || fail "Docker isn't installed"
  (cd "$REPO_DIR" && docker compose up -d --build) || fail "docker compose failed"
  ok "Running in Docker (restarts automatically)"
  echo "   Logs:  cd $REPO_DIR && docker compose logs -f"
  echo "   Stop:  cd $REPO_DIR && docker compose down"
}

bold "4/4  Run it in the background"
case "$(os)" in
  linux) echo "  1) systemd service (recommended)"; default=1 ;;
  macos) echo "  1) launchd (runs while this Mac is on)"; default=1 ;;
  *)     echo "  1) (not available on this system)"; default=2 ;;
esac
echo "  2) Docker"
echo "  3) Don't install a service, I'll run it myself"
ask choice "Choose" "$default"
case "$choice" in
  1) case "$(os)" in linux) install_systemd ;; macos) install_launchd ;; *) fail "choose 2 or 3" ;; esac ;;
  2) install_docker ;;
  *) ok "Skipped. Start it any time with: $UPLOADER" ;;
esac

echo
bold "All set."
echo "The first sync fills in up to 24 hours of readings. New ones follow within ~2 minutes of the G7 app uploading."
echo "Once you see 'Uploaded N reading(s)' in the logs, you can turn off the xDrip phone."
