#!/bin/sh
# Test suite: runs the scripts against a temporary HOME with synthetic
# status-line JSON. Needs only sh and jq. Windows are placed relative to the
# real clock, so every run is deterministic without faking the time.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/claude-usage-guard-test.XXXXXX") || exit 1
trap 'rm -rf "$TMPROOT"' EXIT
export TZ=UTC
export USAGE_GUARD_SKIP_LAUNCHCTL=1
unset USAGE_GUARD_BYPASS USAGE_GUARD_BYPASS_TTL
ESC=$(printf '\033')
passed=0 failed=0 n=0

ok() { passed=$((passed + 1)); echo "ok   $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "$2" ] && echo "     $2"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected to contain [$3], got [$2]" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "expected not to contain [$3], got [$2]" ;; *) ok "$1" ;; esac; }
count_backups() {
  c=0
  for f in "$HOME"/.claude/settings.json.bak-*; do [ -e "$f" ] && c=$((c + 1)); done
  echo "$c"
}
plain() { printf '%s' "$1" | sed "s/${ESC}\[[0-9;]*m//g"; }

# A fresh HOME for each scenario.
new_home() {
  n=$((n + 1))
  HOME="$TMPROOT/home$n"; export HOME
  mkdir -p "$HOME/.claude"
  rm -f "$TMPROOT/out" "$TMPROOT/err"
}
set_conf() { printf '%s\n' "$@" > "$HOME/.claude/usage-guard.conf"; }

# statusline <json>: sets $out to the rendered status line.
statusline() { out=$(printf '%s' "$1" | sh "$ROOT/statusline.sh"); }
# guard <tool>: runs the hook against the recorded figure; sets $rc and $gerr.
# The exit code is read straight from the script, not from a pipeline.
guard() {
  printf '{"tool_name":"%s"}' "$1" > "$TMPROOT/in.json"
  sh "$ROOT/guard.sh" < "$TMPROOT/in.json" > "$TMPROOT/out" 2> "$TMPROOT/err"
  rc=$?
  gerr=$(cat "$TMPROOT/err")
}
write_json() { printf '%s' "$1" > "$HOME/.claude/usage-guard.json"; }

# max_json <5h %> <7d %>: both windows reset in the future.
max_json() {
  now=$(date +%s)
  printf '{"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$1" $((now + 7200)) "$2" $((now + 300000))
}

# ultra_week <day 1-7> : the weekly window is in day <day>, one hour after that
# day began. Sets NOW, START (window start), RESET and DAYSTART.
ultra_week() {
  NOW=$(date +%s)
  START=$((NOW - ($1 - 1) * 86400 - 3600))
  RESET=$((START + 604800))
  DAYSTART=$((START + ($1 - 1) * 86400))
}
ultra_json() { printf '{"rate_limits":{"seven_day":{"used_percentage":%s,"resets_at":%s}}}' "$1" "$RESET"; }

echo "--- max plan"
new_home; set_conf plan=max
statusline "$(max_json 12.7 34.2)"
eq "max status line" "max · 5h 12% · 7d 34%" "$out"
new_home; set_conf plan=pro
statusline "$(max_json 12 34)"
eq "pro status line" "pro · 5h 12% · 7d 34%" "$out"
new_home
statusline "$(max_json 12 34)"
eq "plan defaults to max" "max · 5h 12% · 7d 34%" "$out"
new_home; set_conf plan=max
write_json "$(max_json 91 10)"
guard Agent
eq "max: 5h at 91% refuses an Agent launch (exit 2)" 2 "$rc"
has "refusal names the window" "$gerr" "five_hour window is at 91% (limit 90%)"
has "refusal tells the agent to schedule a wakeup" "$gerr" "schedule a wakeup"
has "refusal hands over the bypass line" "$gerr" "! touch ~/.claude/usage-guard-bypass"
has "refusal addresses the user, neutrally" "$gerr" "the user"
guard Workflow
eq "max: Workflow launch refused too" 2 "$rc"
guard Bash
eq "non-Agent tool passes over the limit (Bash)" 0 "$rc"
guard SendMessage
eq "non-Agent tool passes over the limit (SendMessage)" 0 "$rc"
write_json "$(max_json 89 10)"
guard Agent
eq "max: 5h at 89% passes" 0 "$rc"
write_json "$(max_json 10 90)"
guard Agent
eq "weekly window at 90% refuses" 2 "$rc"
has "weekly refusal names the window" "$gerr" "seven_day window is at 90%"
now=$(date +%s)
write_json "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":99,\"resets_at\":$((now - 10))},\"seven_day\":{\"used_percentage\":5,\"resets_at\":$((now + 9999))}}}"
guard Agent
eq "a window that has already reset is ignored" 0 "$rc"
set_conf plan=max five_hour=80
write_json "$(max_json 85 10)"
guard Agent
eq "five_hour=80 lowers the limit" 2 "$rc"
set_conf plan=max five_hour=off
write_json "$(max_json 99 10)"
guard Agent
eq "five_hour=off disables that window" 0 "$rc"
new_home; set_conf plan=max
guard Agent
eq "no recorded figure: passes" 0 "$rc"

echo "--- a new session, before its first response (no rate_limits)"
new_home; set_conf plan=max
statusline '{"model":{"id":"x"}}'
eq "max: nothing recorded yet shows ?" "max · 5h ?% · 7d ?%" "$out"
write_json "$(max_json 12 34)"
statusline '{"model":{"id":"x"}}'
eq "max: shows the recorded figure" "max · 5h 12% · 7d 34%" "$out"
has "...and leaves the recorded figure in place" "$(cat "$HOME/.claude/usage-guard.json")" "rate_limits"
write_json "$(max_json 95 10)"
statusline '{"model":{"id":"x"}}'
guard Agent
eq "...so the guard still refuses over the limit" 2 "$rc"
now=$(date +%s)
write_json "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":99,\"resets_at\":$((now - 10))},\"seven_day\":{\"used_percentage\":5,\"resets_at\":$((now + 9999))}}}"
statusline '{"model":{"id":"x"}}'
eq "max: a recorded window that has reset shows ?" "max · 5h ?% · 7d 5%" "$out"
new_home; set_conf plan=ultra
ultra_week 4
statusline '{"model":{"id":"x"}}'
eq "ultra: nothing recorded yet shows ?" "ultra · 7d ?" "$out"
printf '%s 1\n' "$DAYSTART" > "$HOME/.claude/usage-guard-day"
printf '%s 15\n' $((NOW - 600)) > "$HOME/.claude/usage-guard-last"
write_json "$(ultra_json 15)"
statusline '{"model":{"id":"x"}}'
eq "ultra: shows the recorded figure" "ultra · 7d 15% · day 4/7 · today 14% of 25% budget used" "$(plain "$out")"
eq "...and does not move the last-reading time" "$((NOW - 600)) 15" "$(cat "$HOME/.claude/usage-guard-last")"

echo "--- ultra plan: budget math and display"
new_home; set_conf plan=ultra
ultra_week 4
printf '%s 1\n' "$DAYSTART" > "$HOME/.claude/usage-guard-day"
statusline "$(ultra_json 1)"
eq "day 4 of 7 starting at 1%: budget 24.75 shows as 25" "ultra · 7d 1% · day 4/7 · today 0% of 25% budget used" "$(plain "$out")"
statusline "$(ultra_json 15)"
eq "usage counts against today's budget" "ultra · 7d 15% · day 4/7 · today 14% of 25% budget used" "$(plain "$out")"
lacks "below 75% of the budget: no colour" "$out" "${ESC}["
statusline "$(ultra_json 20)"
has "75% of the budget: yellow" "$out" "${ESC}[33m"
lacks "75% of the budget: not red" "$out" "${ESC}[31m"
statusline "$(ultra_json 24)"
has "90% of the budget: red" "$out" "${ESC}[31m"
set_conf plan=ultra daily_warn=off
statusline "$(ultra_json 20)"
lacks "daily_warn=off: no yellow" "$out" "${ESC}[33m"
set_conf plan=ultra

echo "--- ultra plan: the guard"
new_home; set_conf plan=ultra
ultra_week 4
printf '%s 1\n' "$DAYSTART" > "$HOME/.claude/usage-guard-day"
write_json "$(ultra_json 20)"
guard Agent
eq "80% of the budget: passes" 0 "$rc"
write_json "$(ultra_json 23.3)"
guard Agent
eq "90.1% of the budget: refuses" 2 "$rc"
has "budget refusal names the day" "$gerr" "day 4 of 7"
has "budget refusal says when the next day opens" "$gerr" "the next day's budget opens at"
has "budget refusal carries the wakeup instruction" "$gerr" "SET A TIMER FOR THE RESET"
write_json "$(ultra_json 22)"
guard Agent
eq "88.9% of the budget: passes" 0 "$rc"
write_json "$(ultra_json 23.3)"
guard Bash
eq "over budget: other tools still pass" 0 "$rc"
set_conf plan=ultra daily=off
guard Agent
eq "daily=off: over-budget day passes" 0 "$rc"
set_conf plan=ultra daily=50
write_json "$(ultra_json 14)"
guard Agent
eq "daily=50 lowers the daily limit" 2 "$rc"
set_conf plan=ultra
write_json "$(ultra_json 90)"
guard Agent
eq "ultra: weekly window at 90% refuses" 2 "$rc"
has "ultra weekly refusal names the window" "$gerr" "seven_day window is at 90%"
set_conf plan=ultra seven_day=off
printf '%s 100\n' "$DAYSTART" > "$HOME/.claude/usage-guard-day"
write_json "$(ultra_json 100)"
guard Agent
eq "a day that began with the week used up has no budget: refuses" 2 "$rc"
has "no-budget refusal says so" "$gerr" "day has no budget"
statusline "$(ultra_json 100)"
eq "no-budget status line" "ultra · 7d 100% · day 4/7 · no budget left today" "$(plain "$out")"
set_conf plan=ultra

echo "--- ultra plan: where the day starts"
new_home; set_conf plan=ultra
ultra_week 4
printf '%s 5\n' $((DAYSTART - 600)) > "$HOME/.claude/usage-guard-last"
statusline "$(ultra_json 8)"
eq "day starts from the last reading before it began (5%)" "ultra · 7d 8% · day 4/7 · today 3% of 24% budget used" "$(plain "$out")"
eq "the day's start is recorded" "$DAYSTART 5" "$(cat "$HOME/.claude/usage-guard-day")"
statusline "$(ultra_json 9)"
has "the recorded start holds for the rest of the day" "$(plain "$out")" "today 4% of 24% budget used"
new_home; set_conf plan=ultra
ultra_week 4
printf '%s 50\n' $((START - 100)) > "$HOME/.claude/usage-guard-last"
statusline "$(ultra_json 8)"
eq "a last reading from the previous week is ignored" "ultra · 7d 8% · day 4/7 · today 0% of 23% budget used" "$(plain "$out")"
eq "the day then starts from the current figure" "$DAYSTART 8" "$(cat "$HOME/.claude/usage-guard-day")"
new_home; set_conf plan=ultra
ultra_week 4
printf '%s 2\n' $((DAYSTART + 60)) > "$HOME/.claude/usage-guard-last"
statusline "$(ultra_json 8)"
eq "a reading taken after the day began is not a day start" "$DAYSTART 8" "$(cat "$HOME/.claude/usage-guard-day")"
new_home; set_conf plan=ultra
ultra_week 1
statusline "$(ultra_json 0)"
eq "day 1 of 7 with nothing used: 14.29% budget shows as 14" "ultra · 7d 0% · day 1/7 · today 0% of 14% budget used" "$(plain "$out")"

echo "--- bypass"
new_home; set_conf plan=max
write_json "$(max_json 95 10)"
touch "$HOME/.claude/usage-guard-bypass"
guard Agent
eq "a fresh bypass flag lets the launch through" 0 "$rc"
has "the bypass is logged" "$(cat "$HOME/.claude/usage-guard-bypass.log")" "bypassed: five_hour window is at 95%"
touch -t 200001010000 "$HOME/.claude/usage-guard-bypass"
guard Agent
eq "an expired bypass flag (older than the TTL) is ignored" 2 "$rc"
USAGE_GUARD_BYPASS_TTL=999999999999 guard Agent
eq "USAGE_GUARD_BYPASS_TTL stretches the flag's life" 0 "$rc"
rm -f "$HOME/.claude/usage-guard-bypass" "$HOME/.claude/usage-guard-bypass.log"
USAGE_GUARD_BYPASS=1 guard Agent
eq "USAGE_GUARD_BYPASS=1 lets the launch through" 0 "$rc"
has "the environment bypass is logged" "$(cat "$HOME/.claude/usage-guard-bypass.log")" "bypassed:"
unset USAGE_GUARD_BYPASS
# touch_at <epoch> <file>: sets a file's mtime (TZ is UTC, so local = UTC).
touch_at() { touch -t "$(date -u -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -u -r "$1" +%Y%m%d%H%M.%S)" "$2"; }

echo "--- bypass for the rest of the day"
new_home; set_conf plan=max
write_json "$(max_json 95 10)"
touch "$HOME/.claude/usage-guard-bypass-today"
guard Agent
eq "a rest-of-day flag touched today lets the launch through" 0 "$rc"
has "the rest-of-day bypass is logged" "$(cat "$HOME/.claude/usage-guard-bypass.log")" "bypassed: five_hour window is at 95%"
statusline "$(max_json 95 10)"
eq "max: the status line says the guard is open until midnight" "max · 5h 95% · 7d 10% · guard open until 00:00" "$out"
now=$(date +%s)
midnight=$((now - $(date +%H | sed 's/^0//;s/^$/0/') * 3600 - $(date +%M | sed 's/^0//;s/^$/0/') * 60 - $(date +%S | sed 's/^0//;s/^$/0/')))
touch_at $((midnight - 60)) "$HOME/.claude/usage-guard-bypass-today"
guard Agent
eq "max: a rest-of-day flag touched yesterday is ignored" 2 "$rc"
has "refusal hands over the rest-of-day line too" "$gerr" "! touch ~/.claude/usage-guard-bypass-today"
statusline "$(max_json 95 10)"
eq "max: a closed guard adds nothing to the status line" "max · 5h 95% · 7d 10%" "$out"
new_home; set_conf plan=ultra
ultra_week 4
printf '%s 1\n' "$DAYSTART" > "$HOME/.claude/usage-guard-day"
write_json "$(ultra_json 23.3)"
touch_at $((DAYSTART - 60)) "$HOME/.claude/usage-guard-bypass-today"
guard Agent
eq "ultra: a flag touched before the budget day began is ignored" 2 "$rc"
touch_at $((DAYSTART + 60)) "$HOME/.claude/usage-guard-bypass-today"
guard Agent
eq "ultra: a flag touched during the budget day lets the launch through" 0 "$rc"
statusline "$(ultra_json 23.3)"
has "ultra: the status line says the guard is open until the next budget opens" "$(plain "$out")" "· guard open until $(date -u -r $((DAYSTART + 86400)) +%H:%M 2>/dev/null || date -u -d "@$((DAYSTART + 86400))" +%H:%M)"

echo "--- portability helpers"
new_home
# shellcheck disable=SC2016  # $1 belongs to the inner sh -c script
helpers=$(cd "$TMPROOT" && sh -c '. "$1/config.sh"; fmt_epoch 1800000000 %H:%M; strip0 08; strip0 00; strip0 10; touch -t 200001010000 f; file_mtime f' sh "$ROOT")
eq "fmt_epoch, strip0 and file_mtime" "08:00
8
0
10
946684800" "$helpers"

echo "--- probe"
stub_claude() {
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\n%s\n' "$1" > "$HOME/.local/bin/claude"
  chmod +x "$HOME/.local/bin/claude"
}
STUB_OK="printf '%s\n' '{\"type\":\"system\"}' '{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{\"seven_day\":{\"utilization\":0.25}}}}'"
# Next day start 2 minutes away: the probe fires on time and records a reading.
new_home; set_conf plan=ultra probe_time=00:59
ultra_week 3; RESET=$((NOW + 4 * 86400 + 120))
write_json "$(ultra_json 20)"
stub_claude "$STUB_OK"
sh "$ROOT/probe.sh"; rc=$?
eq "probe on time: exit 0" 0 "$rc"
read -r _ figure < "$HOME/.claude/usage-guard-last"
eq "probe on time: records the weekly figure (25%)" 25 "$figure"
has "probe on time: logs the reading" "$(cat "$HOME/.claude/usage-guard-probe.log")" "week at 25%"
# A response without a rate_limit_event.
stub_claude "echo '{\"type\":\"system\"}'"
rm -f "$HOME/.claude/usage-guard-last"
sh "$ROOT/probe.sh"; rc=$?
eq "probe without a reading: exit 1" 1 "$rc"
has "probe without a reading: logs it" "$(cat "$HOME/.claude/usage-guard-probe.log")" "no reading"
# A late run (next day start hours away, far from probe_time): sends nothing.
stub_claude "$STUB_OK"
h=$(date +%H); h=${h#0}; h=$(( (${h:-0} + 12) % 24 ))
set_conf plan=ultra "probe_time=$(printf '%02d:30' "$h")"
RESET=$((NOW + 4 * 86400 + 7200)); write_json "$(ultra_json 20)"
rm -f "$HOME/.claude/usage-guard-last"
sh "$ROOT/probe.sh"; rc=$?
eq "late run: exit 0" 0 "$rc"
eq "late run: sends nothing, records nothing" "no" "$([ -e "$HOME/.claude/usage-guard-last" ] && echo yes || echo no)"
has "late run: logs why" "$(cat "$HOME/.claude/usage-guard-probe.log")" "missed"
# The scheduler ran on time but the reset is hours away: the reset has moved.
set_conf plan=ultra "probe_time=$(date +%H:%M)"
sh "$ROOT/probe.sh"; rc=$?
eq "reset moved: exit 1" 1 "$rc"
has "reset moved: logs the new day start" "$(cat "$HOME/.claude/usage-guard-probe.log")" "skipped: the day now starts at"
eq "reset moved: sends nothing" "no" "$([ -e "$HOME/.claude/usage-guard-last" ] && echo yes || echo no)"
# Other plans never probe.
set_conf plan=max
sh "$ROOT/probe.sh"; rc=$?
eq "non-ultra plan: probe does nothing" 0 "$rc"

echo "--- install.sh and uninstall.sh"
new_home
sh "$ROOT/install.sh" --no-probe > "$TMPROOT/o" 2>&1; rc=$?
eq "first install without --plan fails" 1 "$rc"
has "...and says to pass --plan" "$(cat "$TMPROOT/o")" "--plan"
sh "$ROOT/install.sh" --plan turbo > "$TMPROOT/o" 2>&1; rc=$?
eq "an unknown plan is rejected" 1 "$rc"
S="$HOME/.claude/settings.json"
cat > "$S" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/usr/local/bin/other-hook" } ] }
    ],
    "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/stop-hook" } ] } ]
  }
}
JSON
sh "$ROOT/install.sh" --plan max --no-probe > "$TMPROOT/o" 2>&1; rc=$?
eq "install into an existing settings.json: exit 0" 0 "$rc"
eq "conf holds the plan" "plan=max" "$(grep '^plan=' "$HOME/.claude/usage-guard.conf")"
eq "statusLine command points at this clone" "$ROOT/statusline.sh" "$(jq -r .statusLine.command "$S")"
eq "statusLine refreshes every minute" "60" "$(jq -r .statusLine.refreshInterval "$S")"
eq "statusLine type is command" "command" "$(jq -r .statusLine.type "$S")"
eq "the hook is added with the Agent|Workflow matcher" "Agent|Workflow" "$(jq -r --arg g "$ROOT/guard.sh" '.hooks.PreToolUse[] | select(.hooks[].command == $g) | .matcher' "$S")"
eq "the user's own PreToolUse hook survives" "/usr/local/bin/other-hook" "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$S")"
eq "other hook events and keys survive" "opus /usr/local/bin/stop-hook" "$(jq -r '"\(.model) \(.hooks.Stop[0].hooks[0].command)"' "$S")"
eq "a timestamped backup is made" 1 "$(count_backups)"
cp "$S" "$TMPROOT/settings.after-first"
sh "$ROOT/install.sh" --plan max --no-probe > "$TMPROOT/o" 2>&1; rc=$?
eq "second install: exit 0" 0 "$rc"
eq "second install changes nothing (idempotent)" "" "$(diff "$TMPROOT/settings.after-first" "$S")"
eq "second install adds no second hook" 1 "$(jq --arg g "$ROOT/guard.sh" '[.hooks.PreToolUse[] | .hooks[] | select(.command == $g)] | length' "$S")"
eq "second install makes no second backup" 1 "$(count_backups)"
sh "$ROOT/install.sh" --plan pro --no-probe > "$TMPROOT/o" 2>&1
eq "--plan on a re-run updates the conf" "plan=pro" "$(grep '^plan=' "$HOME/.claude/usage-guard.conf")"

new_home
S="$HOME/.claude/settings.json"
printf '{"statusLine":{"type":"command","command":"/opt/theirs/status.sh"},"model":"opus"}\n' > "$S"
cp "$S" "$TMPROOT/settings.theirs"
sh "$ROOT/install.sh" --plan max --no-probe > "$TMPROOT/o" 2>&1; rc=$?
eq "a foreign statusLine is refused" 1 "$rc"
has "...with a message naming it and --force" "$(cat "$TMPROOT/o")" "/opt/theirs/status.sh"
has "...and pointing at --force" "$(cat "$TMPROOT/o")" "--force"
eq "...and settings.json is untouched" "" "$(diff "$TMPROOT/settings.theirs" "$S")"
sh "$ROOT/install.sh" --plan max --no-probe --force > "$TMPROOT/o" 2>&1; rc=$?
eq "--force replaces it" 0 "$rc"
eq "...with ours" "$ROOT/statusline.sh" "$(jq -r .statusLine.command "$S")"
eq "...and keeps the old one in the backup" "/opt/theirs/status.sh" "$(jq -r .statusLine.command "$HOME"/.claude/settings.json.bak-*)"

# uninstall reverses a merge
new_home
S="$HOME/.claude/settings.json"
printf '{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/other-hook"}]}]}}\n' > "$S"
jq . "$S" > "$TMPROOT/settings.orig"
sh "$ROOT/install.sh" --plan max --no-probe > /dev/null 2>&1
sh "$ROOT/uninstall.sh" > "$TMPROOT/o" 2>&1; rc=$?
eq "uninstall: exit 0" 0 "$rc"
eq "uninstall restores the settings (merge reversed)" "" "$(diff "$TMPROOT/settings.orig" "$S")"
eq "uninstall keeps the conf" "yes" "$([ -f "$HOME/.claude/usage-guard.conf" ] && echo yes || echo no)"
sh "$ROOT/uninstall.sh" > "$TMPROOT/o" 2>&1; rc=$?
eq "uninstall twice: exit 0" 0 "$rc"
# uninstall prunes the hook containers it empties, and leaves a foreign statusLine alone
new_home
S="$HOME/.claude/settings.json"
printf '{"statusLine":{"type":"command","command":"/opt/theirs/status.sh"}}\n' > "$S"
sh "$ROOT/install.sh" --plan max --no-probe --force > /dev/null 2>&1
printf '{"statusLine":{"type":"command","command":"/opt/theirs/status.sh"},"hooks":{"PreToolUse":[{"matcher":"Agent|Workflow","hooks":[{"type":"command","command":"%s/guard.sh"}]}]}}\n' "$ROOT" > "$S"
sh "$ROOT/uninstall.sh" > /dev/null 2>&1
eq "uninstall leaves a statusLine that is not ours" "/opt/theirs/status.sh" "$(jq -r .statusLine.command "$S")"
eq "uninstall drops the emptied hooks object" "null" "$(jq -r .hooks "$S")"
sh "$ROOT/uninstall.sh" --purge > /dev/null 2>&1
eq "uninstall --purge deletes the conf" "no" "$([ -f "$HOME/.claude/usage-guard.conf" ] && echo yes || echo no)"

# ultra install: probe time and scheduler
new_home
sh "$ROOT/install.sh" --plan ultra --probe-time 03:30 > "$TMPROOT/o" 2>&1; rc=$?
eq "ultra install with --probe-time: exit 0" 0 "$rc"
eq "probe_time is stored in the conf" "probe_time=03:30" "$(grep '^probe_time=' "$HOME/.claude/usage-guard.conf")"
sh "$ROOT/install.sh" --plan ultra --probe-time 25:99 > "$TMPROOT/o" 2>&1; rc=$?
eq "a malformed --probe-time is rejected" 1 "$rc"
if [ "$(uname -s)" = Darwin ]; then
  P="$HOME/Library/LaunchAgents/com.github.claude-usage-guard.probe.plist"
  eq "macOS: LaunchAgent written" "yes" "$([ -f "$P" ] && echo yes || echo no)"
  has "LaunchAgent runs probe.sh from this clone" "$(cat "$P")" "$ROOT/probe.sh"
  has "LaunchAgent hour" "$(cat "$P")" "<key>Hour</key>
    <integer>3</integer>"
  has "LaunchAgent minute" "$(cat "$P")" "<key>Minute</key>
    <integer>30</integer>"
  has "LaunchAgent label" "$(cat "$P")" "<string>com.github.claude-usage-guard.probe</string>"
  has "LaunchAgent error log under ~/.claude" "$(cat "$P")" "$HOME/.claude/usage-guard-probe.err"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$P" > /dev/null 2>&1; eq "LaunchAgent is a valid plist" 0 "$?"
  fi
  sh "$ROOT/uninstall.sh" > /dev/null 2>&1
  eq "uninstall removes the LaunchAgent" "no" "$([ -f "$P" ] && echo yes || echo no)"
fi
if [ "$(uname -s)" != Darwin ]; then
  new_home
  sh "$ROOT/install.sh" --plan ultra --probe-time 03:30 > "$TMPROOT/o" 2>&1
  has "Linux: prints the crontab line" "$(cat "$TMPROOT/o")" "30 3 * * * $ROOT/probe.sh"
fi
new_home
sh "$ROOT/install.sh" --plan ultra --no-probe > "$TMPROOT/o" 2>&1
eq "--no-probe stores no probe_time" "" "$(grep '^probe_time=' "$HOME/.claude/usage-guard.conf")"
eq "--no-probe schedules nothing" "no" "$([ -e "$HOME/Library/LaunchAgents/com.github.claude-usage-guard.probe.plist" ] && echo yes || echo no)"
new_home
sh "$ROOT/install.sh" --plan ultra > "$TMPROOT/o" 2>&1
eq "no reset recorded and no --probe-time: default 00:59" "probe_time=00:59" "$(grep '^probe_time=' "$HOME/.claude/usage-guard.conf")"
has "...with a note saying so" "$(cat "$TMPROOT/o")" "default"
# 1800000000 is 08:00:00 UTC (TZ=UTC in this suite)
new_home
printf '{"rate_limits":{"seven_day":{"used_percentage":3,"resets_at":1800000000}}}' > "$HOME/.claude/usage-guard.json"
sh "$ROOT/install.sh" --plan ultra > "$TMPROOT/o" 2>&1
eq "probe time derives from the recorded reset (08:00 -> 07:59)" "probe_time=07:59" "$(grep '^probe_time=' "$HOME/.claude/usage-guard.conf")"
printf '{"rate_limits":{"seven_day":{"used_percentage":3,"resets_at":1799971200}}}' > "$HOME/.claude/usage-guard.json"
sh "$ROOT/install.sh" --plan ultra > "$TMPROOT/o" 2>&1
eq "a reset at 00:00 puts the probe at 23:59" "probe_time=23:59" "$(grep '^probe_time=' "$HOME/.claude/usage-guard.conf")"
eq "re-running keeps one probe_time line" 1 "$(grep -c '^probe_time=' "$HOME/.claude/usage-guard.conf")"
sh "$ROOT/install.sh" --plan ultra --probe-time 04:15 > "$TMPROOT/o" 2>&1
eq "--probe-time outranks the derived time" "probe_time=04:15" "$(grep '^probe_time=' "$HOME/.claude/usage-guard.conf")"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
