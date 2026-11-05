#!/bin/sh
# Reads the weekly usage just before each day of the ultra plan begins, so the
# day's budget starts from a fresh figure even when no Claude Code session is
# open. A scheduler (launchd on macOS, cron on Linux; install.sh sets it up)
# runs it once a day at probe_time (usage-guard.conf), a minute before the day
# starts at the account's weekly reset time of day. It sends one small Haiku
# "ok", with no hooks, settings or saved session, and writes the weekly figure
# to ~/.claude/usage-guard-last, the last reading before the day begins, which
# is what pace.jq starts the day from.
# If the next day start, counted from the account's weekly reset, is not within
# PROBE_LEAD seconds (default 300) of the run, either the reset has moved
# (daylight saving time moves its time of day) and probe_time needs changing,
# or the scheduler ran this late (see below).
# launchd runs a missed job once the machine wakes from sleep and skips one
# missed while it is shut down; a late run sends nothing, since a reading taken
# after the day began includes that day's usage.
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
# shellcheck source=config.sh
. "$(dirname "$0")/config.sh"
[ "$plan" = ultra ] || exit 0
lead=${PROBE_LEAD:-300}
probe_time=$(conf_get probe_time 00:59)
now=$(date +%s)
log="$HOME/.claude/usage-guard-probe.log"
reset=$(jq -r '.rate_limits.seven_day.resets_at // 0 | floor' "$HOME/.claude/usage-guard.json" 2>/dev/null)
if [ "${reset:-0}" -gt 0 ]; then
  # The window recurs weekly; roll a past reset forward, then find the next day start.
  while [ "$reset" -le "$now" ]; do reset=$((reset + 604800)); done
  next=$((reset - ((reset - now) / 86400) * 86400))
  [ "$next" -le "$now" ] && next=$((next + 86400))
  if [ $((next - now)) -gt "$lead" ]; then
    # Within five minutes of probe_time the scheduler ran on time, so the reset
    # has moved; otherwise the run is late.
    cur=$(( $(strip0 "$(date +%H)") * 60 + $(strip0 "$(date +%M)") ))
    want=$(( $(strip0 "${probe_time%:*}") * 60 + $(strip0 "${probe_time#*:}") ))
    diff=$((cur - want)); [ "$diff" -lt 0 ] && diff=$((0 - diff))
    [ "$diff" -gt 720 ] && diff=$((1440 - diff))
    if [ "$diff" -le 5 ]; then
      echo "$(date '+%F %T') skipped: the day now starts at $(fmt_epoch "$next" %H:%M), not a minute after probe_time ${probe_time}; set probe_time a minute before the day start (re-run install.sh, or pass --probe-time)" >> "$log"
      exit 1
    fi
    echo "$(date '+%F %T') missed ${probe_time} (the machine was asleep); today starts from the last reading before the day began" >> "$log"
    exit 0
  fi
fi
dir="$HOME/.claude/usage-guard-probe.d"; mkdir -p "$dir"; cd "$dir" || exit 1
used=$(claude -p ok --model haiku --setting-sources project --no-session-persistence \
  --output-format stream-json --verbose 2>/dev/null |
  jq -r 'select(.type=="rate_limit_event") | .rate_limit_info.unifiedWindows.seven_day.utilization // empty | . * 100' 2>/dev/null | tail -1)
if [ -z "$used" ]; then
  echo "$(date '+%F %T') no reading" >> "$log"; exit 1
fi
printf '%s %s\n' "$(date +%s)" "$used" > "$lastread.$$" && mv "$lastread.$$" "$lastread"
echo "$(date '+%F %T') week at ${used}%" >> "$log"
