# shellcheck shell=sh
# Sourced by guard.sh, statusline.sh, probe.sh and install.sh. Reads
# ~/.claude/usage-guard.conf, one `key=value` per line (`#` starts a comment):
#   plan=pro | max | ultra   which windows the guard enforces (default max)
#                            pro, max: the 5-hour window and the weekly window
#                            ultra:    the weekly window and the daily budget
#   five_hour=90             percent of the 5-hour window (pro, max)
#   seven_day=90             percent of the weekly window (every plan)
#   daily=90                 percent of the day's budget (ultra; pace.jq)
#   daily_warn=75            the status line turns yellow here (ultra)
#   probe_time=00:59         local time the day-start probe runs (ultra);
#                            install.sh derives it, probe.sh reads it
# A limit is a percentage or `off`; each defaults to 90 (daily_warn to 75).
# The user opens the guard with a flag file (bypass_ends, below).
# shellcheck disable=SC2034  # the variables below are read by the scripts that source this file
conf="$HOME/.claude/usage-guard.conf"
ug_dir=$(dirname "$0")
conf_get() {
  _v=""
  [ -r "$conf" ] && _v=$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([A-Za-z0-9:]+)[[:space:]]*(#.*)?$/\1/p" "$conf" | tail -1)
  echo "${_v:-$2}"
}
plan=$(conf_get plan max)
# The day's budget is fixed from the week's usage when the day began, recorded
# by statusline.sh as `<day start epoch> <percent used>`; the status line also
# keeps its latest reading as `<epoch> <percent used>`.
daystate="$HOME/.claude/usage-guard-day"
lastread="$HOME/.claude/usage-guard-last"
# Portability helpers: the macOS (BSD) and Linux (GNU) tools differ here, and
# each form fails cleanly on the other system, so try one and fall back.
# file_mtime <path>: modification time, epoch seconds.
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
# fmt_epoch <epoch> <date format without the leading +>: local time of an epoch.
fmt_epoch() { date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2" 2>/dev/null; }
# strip0 <number>: drops leading zeros so shell arithmetic does not read octal.
strip0() { _s=${1#0}; echo "${_s:-0}"; }
# pace <json file> [fields]: runs pace.jq with the recorded start-of-day usage.
pace() {
  _bd=0 _bb=0 _la=0 _lu=0
  [ -r "$daystate" ] && read -r _bd _bb < "$daystate"
  [ -r "$lastread" ] && read -r _la _lu < "$lastread"
  jq -r --argjson now "$(date +%s)" --argjson base_day "${_bd:-0}" --argjson base "${_bb:-0}" \
    --argjson last_at "${_la:-0}" --argjson last_used "${_lu:-0}" \
    "$(cat "$ug_dir/pace.jq") | $2" "$1" 2>/dev/null
}
# The user's bypass flags. usage-guard-bypass opens the guard for
# USAGE_GUARD_BYPASS_TTL seconds (default 30 minutes) after it is touched;
# usage-guard-bypass-today opens it for the rest of the day it was touched in:
# on ultra the budget day (pace.jq), so it lasts until the next budget opens;
# otherwise the local calendar day.
bypass="$HOME/.claude/usage-guard-bypass"
bypass_today="$HOME/.claude/usage-guard-bypass-today"
# bypass_ends: epoch seconds when the open bypass expires, or nothing when no
# flag is open. With both flags open, the later expiry counts.
bypass_ends() {
  _now=$(date +%s) _end=0
  if [ -f "$bypass" ]; then
    _e=$(( $(file_mtime "$bypass") + ${USAGE_GUARD_BYPASS_TTL:-1800} ))
    [ "$_e" -gt "$_now" ] && _end=$_e
  fi
  if [ -f "$bypass_today" ]; then
    _m=$(file_mtime "$bypass_today") _ds=""
    [ "$plan" = ultra ] && _ds=$(pace "$HOME/.claude/usage-guard.json" '"\(.day_start)"')
    if [ -n "$_ds" ]; then
      [ "$_m" -ge "$_ds" ] && _e=$((_ds + 86400)) || _e=0
    elif [ "$(fmt_epoch "$_m" %F)" = "$(date +%F)" ]; then
      # Next midnight, for display; off by an hour on a daylight saving day.
      _e=$(( _now + 86400 - $(strip0 "$(date +%H)") * 3600 - $(strip0 "$(date +%M)") * 60 - $(strip0 "$(date +%S)") ))
    else _e=0; fi
    [ "$_e" -gt "$_end" ] && _end=$_e
  fi
  [ "$_end" -gt 0 ] && echo "$_end"
  return 0
}
