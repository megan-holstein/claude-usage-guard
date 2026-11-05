#!/bin/sh
# PreToolUse hook on the subagent-launching tools (Agent, Workflow): refuses a
# new subagent once a usage limit is reached. Nothing else is ever refused, so
# work in flight, an orchestrator's or a subagent's, finishes and lands instead
# of being stranded by a limit that stops everything at once.
# Reads the figure statusline.sh records; a figure whose window has already
# reset is stale and ignored.
# Which windows it enforces depends on the plan in ~/.claude/usage-guard.conf
# (config.sh): on pro and max the 5-hour and weekly windows; on ultra the weekly
# window and the day's budget (pace.jq), so a week's usage is paced across its
# seven days.
# shellcheck source=config.sh
. "$(dirname "$0")/config.sh"
f="$HOME/.claude/usage-guard.json"
[ -r "$f" ] || exit 0
now=$(date +%s)
tool=$(jq -r '.tool_name // empty' 2>/dev/null)
case "$tool" in Agent|Workflow) ;; *) exit 0 ;; esac
over=""; opens="it resets"
case "$plan" in ultra) windows=seven_day ;; *) windows="five_hour seven_day" ;; esac
for w in $windows; do
  pct=$(jq -r ".rate_limits.$w.used_percentage // 0" "$f" 2>/dev/null)
  reset=$(jq -r ".rate_limits.$w.resets_at // 0" "$f" 2>/dev/null)
  [ "${reset%.*}" -gt "$now" ] 2>/dev/null || continue
  lim=$(conf_get "$w" 90)
  [ "$lim" = off ] && continue
  [ "${pct%.*}" -ge "$lim" ] 2>/dev/null && { over="${w} window is at ${pct}% (limit ${lim}%)"; over_reset=${reset%.*}; }
done
dlim=$(conf_get daily 90)
if [ "$plan" = ultra ] && [ -z "$over" ] && [ "$dlim" != off ]; then
  p=$(pace "$f" '"\(.today|floor) \(.day) \(.budget*10|round/10) \(.day_ends)"')
  if [ -n "$p" ]; then
    # shellcheck disable=SC2086  # split the space-separated fields on purpose
    set -- $p
    [ "$1" -ge "$dlim" ] 2>/dev/null && {
      case "$3" in
        -*|0) over="day has no budget (limit ${dlim}%): day $2 of 7 began with the weekly window used up" ;;
        *) over="day's budget is ${1}% used (limit ${dlim}%): day $2 of 7 of the weekly window, whose budget today is ${3}% of the week" ;;
      esac
      over_reset=$4; opens="the next day's budget opens"
    }
  fi
fi
[ -n "$over" ] || exit 0
# Optional bypass: USAGE_GUARD_BYPASS=1 in the environment, or a flag file
# touched within the last USAGE_GUARD_BYPASS_TTL seconds (default 30 minutes), so
# a forgotten flag expires. Every bypassed call is logged. Only the user sets
# the flag; the refusal below hands the agent the command to print for them.
bypass="$HOME/.claude/usage-guard-bypass"
ttl=${USAGE_GUARD_BYPASS_TTL:-1800}
if [ -f "$bypass" ]; then mtime=$(file_mtime "$bypass"); else mtime=0; fi
if [ "$USAGE_GUARD_BYPASS" = 1 ] ||
   { [ -f "$bypass" ] && [ $((now - ${mtime:-0})) -lt "$ttl" ]; }; then
  echo "$(date '+%F %T') bypassed: $over" >> "$HOME/.claude/usage-guard-bypass.log"
  exit 0
fi
reset_at=$(fmt_epoch "$over_reset" '%F %T' || echo unknown)
[ -n "$reset_at" ] || reset_at=unknown
wait_s=$((over_reset - now)); [ "$wait_s" -gt 0 ] || wait_s=0
echo "Usage guard: the ${over}; ${opens} at ${reset_at} (in ${wait_s}s). Launch no new subagent and start no new task until then. Everything else still runs: finish, verify, land and record the work already in flight, and resume a stopped subagent (SendMessage) if its task is unfinished. SET A TIMER FOR THE RESET: schedule a wakeup for ${reset_at} (ScheduleWakeup, chaining wakeups of up to 3600s until then, or a one-shot CronCreate), and when it fires retry the refused subagent and go on with the chain. Say where things stand, and end your reply with this line, verbatim, so the user can open the guard sooner if they are at their computer: ! touch ~/.claude/usage-guard-bypass" >&2
exit 2
