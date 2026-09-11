#!/usr/bin/env bash
# fm-projets-serve.sh - keep the base's stable front door up on the tailnet.
#
# The captain wants one address that never changes for the projets page and
# for whatever else the base serves, reachable from every one of his machines
# by the MagicDNS name, surviving a reboot. bin/fm-projets-serve.py is the
# server (index at /, the page at /projets, declared folders at /fichiers/);
# this script runs it and owns its launchd user agent, which is private
# material of the home, never tracked: the plist is written under
# $FM_HOME/config/ and linked from ~/Library/LaunchAgents/ so launchd loads it
# at login and restarts it when it dies (KeepAlive).
#
# Usage:
#   fm-projets-serve.sh run                 serve in the foreground (what launchd runs)
#   fm-projets-serve.sh install             write the plist, link it, load it, start it
#   fm-projets-serve.sh uninstall           stop it, unload it, remove the link and the plist
#   fm-projets-serve.sh start|stop          load or unload the agent without touching the plist
#   fm-projets-serve.sh status              launchd state plus one real request to the index
#   fm-projets-serve.sh url                 print the stable base URL (index) and the page URL
#
# The port and the published host name come from config/projets-serve.json
# (schema fm-projets-serve.v1, owned by docs/configuration.md "Stable page
# address"); the default port is 4390 and the default host is this machine's
# hostname. The agent label is co.firstmate.projets-serve.<home-hash> so two
# homes on one machine never fight over one label.
#
# FM_PROJETS_SERVE_LAUNCH_AGENTS overrides ~/Library/LaunchAgents (tests).
# launchctl is taken from PATH so a test can stand in for it.
#
# The tailnet only covers the captain's own machines: nothing here is a
# client-facing surface. Client pages go through a paid subdomain, a separate
# piece of work.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LAUNCH_AGENTS="${FM_PROJETS_SERVE_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
SERVER="$SCRIPT_DIR/fm-projets-serve.py"
TABLE="$CONFIG/projets-serve.json"
DEFAULT_PORT=4390

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-projets-serve: %s\n' "$*" >&2
  exit 1
}

home_hash() {
  printf '%s' "$FM_HOME" | cksum | awk '{ print $1 }'
}

label() { printf 'co.firstmate.projets-serve.%s\n' "$(home_hash)"; }
plist_path() { printf '%s/%s.plist\n' "$CONFIG" "$(label)"; }
link_path() { printf '%s/%s.plist\n' "$LAUNCH_AGENTS" "$(label)"; }

port() {
  local p=""
  if [ -f "$TABLE" ] && command -v jq >/dev/null 2>&1; then
    p=$(jq -r 'if (.port | type) == "number" then (.port | tostring) else "" end' "$TABLE" 2>/dev/null || true)
  fi
  case "$p" in ''|*[!0-9]*) p=$DEFAULT_PORT ;; esac
  printf '%s\n' "$p"
}

host() {
  local h=""
  if [ -f "$TABLE" ] && command -v jq >/dev/null 2>&1; then
    h=$(jq -r '.host // ""' "$TABLE" 2>/dev/null || true)
  fi
  [ -n "$h" ] || h=$(hostname)
  printf '%s\n' "$h"
}

base_url() { printf 'http://%s:%s/\n' "$(host)" "$(port)"; }

xml_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

write_plist() {
  local target=$1 py tmp
  py=$(command -v python3) || fail "python3 is required"
  (umask 077; mkdir -p "$CONFIG" "$STATE") || fail "cannot create $CONFIG"
  tmp=$(umask 077; mktemp "$CONFIG/.projets-serve.XXXXXX") || fail "cannot stage the plist"
  cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$(xml_escape "$(label)")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$py")</string>
    <string>$(xml_escape "$SERVER")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key><string>$(xml_escape "$FM_HOME")</string>
    <key>PATH</key><string>$(xml_escape "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$(xml_escape "$STATE/projets-serve.log")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$STATE/projets-serve.log")</string>
</dict>
</plist>
EOF
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$target"; }; then
    rm -f -- "$tmp"
    fail "cannot write the plist"
  fi
}

domain() { printf 'gui/%s\n' "$(id -u)"; }

loaded() {
  launchctl print "$(domain)/$(label)" >/dev/null 2>&1
}

command_run() {
  [ -f "$SERVER" ] || fail "server missing: $SERVER"
  exec python3 "$SERVER"
}

command_install() {
  local plist link
  command -v launchctl >/dev/null 2>&1 || fail "launchctl is required (macOS launchd user agent)"
  plist=$(plist_path)
  link=$(link_path)
  write_plist "$plist"
  mkdir -p "$LAUNCH_AGENTS" || fail "cannot create $LAUNCH_AGENTS"
  ln -sfn "$plist" "$link" || fail "cannot link the plist into $LAUNCH_AGENTS"
  if loaded; then
    launchctl kickstart -k "$(domain)/$(label)" >/dev/null 2>&1 || fail "cannot restart the agent"
    printf 'restarted: %s\n' "$(label)"
  else
    launchctl bootstrap "$(domain)" "$link" >/dev/null 2>&1 || fail "cannot load the agent (launchctl bootstrap)"
    printf 'installed: %s\n' "$(label)"
  fi
  printf 'plist: %s\n' "$plist"
  printf 'link: %s\n' "$link"
  printf 'url: %s\n' "$(base_url)"
}

command_uninstall() {
  local plist link
  command -v launchctl >/dev/null 2>&1 || fail "launchctl is required"
  plist=$(plist_path)
  link=$(link_path)
  if loaded; then
    launchctl bootout "$(domain)/$(label)" >/dev/null 2>&1 || fail "cannot unload the agent"
  fi
  rm -f -- "$link" "$plist"
  printf 'uninstalled: %s\n' "$(label)"
}

command_start() {
  local link
  command -v launchctl >/dev/null 2>&1 || fail "launchctl is required"
  link=$(link_path)
  [ -e "$link" ] || fail "not installed: run install first"
  if loaded; then
    launchctl kickstart -k "$(domain)/$(label)" >/dev/null 2>&1 || fail "cannot start the agent"
  else
    launchctl bootstrap "$(domain)" "$link" >/dev/null 2>&1 || fail "cannot load the agent"
  fi
  printf 'started: %s\n' "$(label)"
}

command_stop() {
  command -v launchctl >/dev/null 2>&1 || fail "launchctl is required"
  if loaded; then
    launchctl bootout "$(domain)/$(label)" >/dev/null 2>&1 || fail "cannot stop the agent"
    printf 'stopped: %s\n' "$(label)"
  else
    printf 'not-running: %s\n' "$(label)"
  fi
}

command_status() {
  local url code
  if command -v launchctl >/dev/null 2>&1 && loaded; then
    printf 'agent: loaded (%s)\n' "$(label)"
  else
    printf 'agent: not loaded (%s)\n' "$(label)"
  fi
  url=$(base_url)
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || true)
    if [ "$code" = 200 ]; then printf 'index: repond (%s)\n' "$url"; else printf 'index: ne repond pas (%s)\n' "$url"; fi
  else
    printf 'index: non teste, curl absent (%s)\n' "$url"
  fi
  [ -f "$STATE/projets-serve.log" ] && printf 'log: %s\n' "$STATE/projets-serve.log"
  return 0
}

command_url() {
  printf 'base: %s\n' "$(base_url)"
  printf 'page: %sprojets\n' "$(base_url)"
}

case "${1-}" in
  run) command_run ;;
  install) command_install ;;
  uninstall) command_uninstall ;;
  start) command_start ;;
  stop) command_stop ;;
  status) command_status ;;
  url) command_url ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
