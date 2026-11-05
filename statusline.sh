#!/bin/sh
# Status line: shows the plan's usage and records the JSON for guard.sh.
#   pro, max: `max · 5h NN% · 7d NN%`
#   ultra:    `ultra · 7d NN% · day N/7 · today NN% of NN% budget used`, both
#             in percent of the week; yellow at daily_warn and red at the
#             daily limit, each a percentage of the day's budget.
# On ultra it also records the week's usage when each day begins, and its own
# latest reading (config.sh).
input=$(cat)
f="$HOME/.claude/usage-guard.json"
printf '%s' "$input" > "$f"
# shellcheck source=config.sh
. "$(dirname "$0")/config.sh"
pct() { printf '%s' "$input" | jq -r ".rate_limits.$1.used_percentage // empty | floor" 2>/dev/null; }
if [ "$plan" != ultra ]; then
  h5=$(pct five_hour) d7=$(pct seven_day)
  printf '%s · 5h %s%% · 7d %s%%' "$plan" "${h5:-?}" "${d7:-?}"
  exit 0
fi
p=$(pace "$f" '"\(.day_start) \(.used) \(.day) \(.today|floor) \(.budget|round) \(.spent|round) \(.baseline)"')
[ -n "$p" ] || { printf 'ultra · 7d ?'; exit 0; }
# shellcheck disable=SC2086  # split the space-separated fields on purpose
set -- $p
day_start=$1 used=$2 day=$3 today=$4 budget=$5 spent=$6 baseline=$7
_bd=0; [ -r "$daystate" ] && read -r _bd _ < "$daystate"
if [ "$_bd" != "$day_start" ]; then
  printf '%s %s\n' "$day_start" "$baseline" > "$daystate.$$" && mv "$daystate.$$" "$daystate"
fi
printf '%s %s\n' "$(date +%s)" "$used" > "$lastread.$$" && mv "$lastread.$$" "$lastread"
warn=$(conf_get daily_warn 75) stop=$(conf_get daily 90) color=""
[ "$warn" != off ] && [ "$today" -ge "$warn" ] && color='\033[33m'
[ "$stop" != off ] && [ "$today" -ge "$stop" ] && color='\033[31m'
if [ "$budget" -gt 0 ]; then msg="today ${spent}% of ${budget}% budget used"; else msg="no budget left today"; fi
# shellcheck disable=SC2059  # $color holds an escape sequence the format must interpret
printf "ultra · 7d %s%% · day %s/7 · ${color}%s" "${used%.*}" "$day" "$msg"
[ -n "$color" ] && printf '\033[0m'
exit 0
