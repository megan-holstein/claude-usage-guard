#!/bin/sh
# Status line: shows the plan's usage and records the JSON for guard.sh.
#   pro, max: `max · 5h NN% · 7d NN%`
#   ultra:    `ultra · 7d NN% · day N/7 · today NN% of NN% budget used`, both
#             in percent of the week; yellow at daily_warn and red at the
#             daily limit, each a percentage of the day's budget.
# On ultra it also records the week's usage when each day begins, and its own
# latest reading (config.sh).
# While the user's bypass is open it appends `· guard open until HH:MM`.
# Claude Code sends no rate_limits until a session's first API response, so a
# new window keeps the figure the last reading recorded (from any session; the
# windows are account-wide) and shows that instead of `?`. A window that has
# reset since is ignored, here and in pace.jq.
input=$(cat)
f="$HOME/.claude/usage-guard.json"
fresh=0
if printf '%s' "$input" | jq -e '.rate_limits | type == "object"' >/dev/null 2>&1; then
  printf '%s' "$input" > "$f" && fresh=1
fi
# shellcheck source=config.sh
. "$(dirname "$0")/config.sh"
# open_note: the bypass suffix, or nothing while the guard is closed.
open_note() { _b=$(bypass_ends); [ -n "$_b" ] && printf ' · guard open until %s' "$(fmt_epoch "$_b" %H:%M)"; return 0; }
pct() { jq -r --argjson now "$(date +%s)" ".rate_limits.$1 | select((.resets_at // 0) > \$now) | .used_percentage // empty | floor" "$f" 2>/dev/null; }
if [ "$plan" != ultra ]; then
  h5=$(pct five_hour) d7=$(pct seven_day)
  printf '%s · 5h %s%% · 7d %s%%%s' "$plan" "${h5:-?}" "${d7:-?}" "$(open_note)"
  exit 0
fi
p=$(pace "$f" '"\(.day_start) \(.used) \(.day) \(.today|floor) \(.budget|round) \(.spent|round) \(.baseline)"')
[ -n "$p" ] || { printf 'ultra · 7d ?%s' "$(open_note)"; exit 0; }
# shellcheck disable=SC2086  # split the space-separated fields on purpose
set -- $p
day_start=$1 used=$2 day=$3 today=$4 budget=$5 spent=$6 baseline=$7
_bd=0; [ -r "$daystate" ] && read -r _bd _ < "$daystate"
if [ "$_bd" != "$day_start" ]; then
  printf '%s %s\n' "$day_start" "$baseline" > "$daystate.$$" && mv "$daystate.$$" "$daystate"
fi
# Only a fresh reading moves the last-reading time; a recorded one is already there.
[ "$fresh" = 1 ] && { printf '%s %s\n' "$(date +%s)" "$used" > "$lastread.$$" && mv "$lastread.$$" "$lastread"; }
warn=$(conf_get daily_warn 75) stop=$(conf_get daily 90) color=""
[ "$warn" != off ] && [ "$today" -ge "$warn" ] && color='\033[33m'
[ "$stop" != off ] && [ "$today" -ge "$stop" ] && color='\033[31m'
if [ "$budget" -gt 0 ]; then msg="today ${spent}% of ${budget}% budget used"; else msg="no budget left today"; fi
# shellcheck disable=SC2059  # $color holds an escape sequence the format must interpret
printf "ultra · 7d %s%% · day %s/7 · ${color}%s" "${used%.*}" "$day" "$msg"
[ -n "$color" ] && printf '\033[0m'
printf '%s' "$(open_note)"
exit 0
