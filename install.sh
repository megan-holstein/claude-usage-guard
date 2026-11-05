#!/bin/sh
# Installs usage-guard from this clone: writes ~/.claude/usage-guard.conf,
# merges the status line and the PreToolUse hook into ~/.claude/settings.json
# (after a timestamped backup), and on the ultra plan schedules the day-start
# probe. Safe to run again. Everything lives under $HOME, so a test can point
# HOME at a scratch directory.
usage() {
  cat <<'USAGE'
Usage: install.sh [--plan pro|max|ultra] [--probe-time HH:MM] [--no-probe] [--force]

  --plan         your plan; required the first time (written to ~/.claude/usage-guard.conf)
  --probe-time   local time the ultra plan's day-start probe runs; by default derived
                 from the weekly reset recorded in ~/.claude/usage-guard.json, else 00:59
  --no-probe     do not schedule the probe
  --force        replace a statusLine that belongs to something else

Environment: USAGE_GUARD_SKIP_LAUNCHCTL=1 writes the macOS LaunchAgent without loading it.
USAGE
}
die() { echo "install.sh: $*" >&2; exit 1; }

plan_arg="" probe_arg="" no_probe=0 force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) [ $# -ge 2 ] || die "--plan needs a value"; plan_arg=$2; shift 2 ;;
    --plan=*) plan_arg=${1#--plan=}; shift ;;
    --probe-time) [ $# -ge 2 ] || die "--probe-time needs a value"; probe_arg=$2; shift 2 ;;
    --probe-time=*) probe_arg=${1#--probe-time=}; shift ;;
    --no-probe) no_probe=1; shift ;;
    --force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

dir=$(cd "$(dirname "$0")" && pwd) || die "cannot resolve the clone's path"
case "$dir" in *[[:space:]]*) die "the clone's path contains whitespace ($dir); settings.json commands cannot quote it. Move the clone." ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required (macOS: brew install jq; Debian/Ubuntu: apt install jq)"
# shellcheck source=config.sh
. "$dir/config.sh"
mkdir -p "$HOME/.claude" || die "cannot create $HOME/.claude"
stamp=$(date +%Y%m%d-%H%M%S)

# set_conf <key> <value>: replaces the key's line in the conf, or appends it.
set_conf() {
  _tmp="$conf.$$"
  { [ -f "$conf" ] && grep -Ev "^[[:space:]]*$1[[:space:]]*=" "$conf"; printf '%s=%s\n' "$1" "$2"; } > "$_tmp" && mv "$_tmp" "$conf"
}

# --- the conf file -----------------------------------------------------------
if [ -n "$plan_arg" ]; then
  case "$plan_arg" in pro|max|ultra) ;; *) die "--plan must be pro, max or ultra" ;; esac
fi
if [ ! -f "$conf" ]; then
  [ -n "$plan_arg" ] || die "pass --plan pro, --plan max or --plan ultra on the first install"
  printf '# usage-guard configuration; the keys are documented in config.sh and the README.\n' > "$conf"
  set_conf plan "$plan_arg"
  echo "wrote $conf (plan=$plan_arg)"
elif [ -n "$plan_arg" ] && [ "$(conf_get plan max)" != "$plan_arg" ]; then
  set_conf plan "$plan_arg"
  echo "set plan=$plan_arg in $conf"
fi
plan=$(conf_get plan max)

# --- settings.json -----------------------------------------------------------
settings="$HOME/.claude/settings.json"
sl="$dir/statusline.sh" guard="$dir/guard.sh"
if [ -f "$settings" ]; then
  jq -e 'type == "object"' "$settings" >/dev/null 2>&1 || die "$settings is not a JSON object; fix it and run again"
  src=$settings
else
  src="$settings.new.$$.in"; printf '{}\n' > "$src"
fi
cur=$(jq -r 'if .statusLine == null then "" else (.statusLine.command // "(not a command)") end' "$src")
if [ -n "$cur" ] && [ "$cur" != "$sl" ] && [ "$force" -ne 1 ]; then
  [ "$src" = "$settings" ] || rm -f "$src"
  die "$settings already has a different statusLine ($cur). Re-run with --force to replace it; the old one is kept in the backup."
fi
new="$settings.new.$$"
jq --arg sl "$sl" --arg g "$guard" '
  def ours: any((.hooks // [])[]?; .command == $g);
  .statusLine = {type: "command", command: $sl, refreshInterval: 60}
  | .hooks.PreToolUse = ((.hooks.PreToolUse // [])
      | if any(.[]; ours) then .
        else . + [{matcher: "Agent|Workflow", hooks: [{type: "command", command: $g}]}] end)
' "$src" > "$new" || { rm -f "$new"; [ "$src" = "$settings" ] || rm -f "$src"; die "could not merge into $settings"; }
if [ -f "$settings" ] && cmp -s "$new" "$settings"; then
  rm -f "$new"; echo "$settings already holds the status line and the hook"
else
  if [ -f "$settings" ]; then
    cp "$settings" "$settings.bak-$stamp" || die "could not back up $settings"
    echo "backed up $settings to $settings.bak-$stamp"
  fi
  mv "$new" "$settings" || die "could not write $settings"
  echo "merged the status line and the PreToolUse hook (Agent|Workflow) into $settings"
fi
[ "$src" = "$settings" ] || rm -f "$src"

# --- the day-start probe (ultra only) ----------------------------------------
label=com.github.usage-guard.probe
plist="$HOME/Library/LaunchAgents/$label.plist"
os=$(uname -s)
uid=$(id -u)
unload() { [ "${USAGE_GUARD_SKIP_LAUNCHCTL:-}" = 1 ] || launchctl bootout "gui/$uid" "$plist" >/dev/null 2>&1; }

if [ "$plan" != ultra ] || [ "$no_probe" -eq 1 ]; then
  if [ -f "$plist" ]; then unload; rm -f "$plist"; echo "removed the probe's LaunchAgent"; fi
  [ "$plan" = ultra ] && echo "probe skipped (--no-probe): the daily budget starts from the last status-line reading before each day"
  echo "done."
  exit 0
fi

if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ] &&
   [ ! -x /opt/homebrew/bin/claude ] && [ ! -x /usr/local/bin/claude ]; then
  echo "warning: claude is not on PATH; the probe logs 'no reading' until it is"
fi

valid_time() { printf '%s' "$1" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$'; }
note=""
if [ -n "$probe_arg" ]; then
  valid_time "$probe_arg" || die "--probe-time must be HH:MM, 24-hour"
  probe_time=$probe_arg
else
  reset=$(jq -r '.rate_limits.seven_day.resets_at // empty | floor' "$HOME/.claude/usage-guard.json" 2>/dev/null)
  tod=""
  [ -n "$reset" ] && tod=$(fmt_epoch "$reset" %H:%M)
  if valid_time "$tod"; then
    mins=$(( $(strip0 "${tod%:*}") * 60 + $(strip0 "${tod#*:}") - 1 ))
    [ "$mins" -lt 0 ] && mins=1439
    probe_time=$(printf '%02d:%02d' $((mins / 60)) $((mins % 60)))
    note="derived from the weekly reset at $tod recorded in ~/.claude/usage-guard.json"
  elif valid_time "$(conf_get probe_time x)"; then
    probe_time=$(conf_get probe_time x)
    note="kept from $conf (no weekly reset is recorded yet)"
  else
    probe_time=00:59
    note="default: no weekly reset is recorded yet. Start Claude Code once, then re-run install.sh to derive it, or pass --probe-time HH:MM (a minute before your weekly reset's time of day)"
  fi
fi
set_conf probe_time "$probe_time"
echo "probe time: $probe_time${note:+ ($note)}"
ph=$(strip0 "${probe_time%:*}") pm=$(strip0 "${probe_time#*:}")

if [ "$os" = Darwin ]; then
  esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
  mkdir -p "$HOME/Library/LaunchAgents" || die "cannot create $HOME/Library/LaunchAgents"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(esc "$dir/probe.sh")</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$ph</integer>
    <key>Minute</key>
    <integer>$pm</integer>
  </dict>
  <key>StandardErrorPath</key>
  <string>$(esc "$HOME/.claude/usage-guard-probe.err")</string>
</dict>
</plist>
PLIST
  echo "wrote $plist"
  if [ "${USAGE_GUARD_SKIP_LAUNCHCTL:-}" = 1 ]; then
    echo "USAGE_GUARD_SKIP_LAUNCHCTL=1: not loading it"
  else
    unload
    launchctl bootstrap "gui/$uid" "$plist" || die "launchctl could not load $plist"
    echo "loaded $label"
  fi
else
  echo "Add this line to your crontab (crontab -e) to run the probe daily:"
  echo "$pm $ph * * * $dir/probe.sh"
fi
echo "done."
