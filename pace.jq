# Daily pacing of the 7-day usage window, shared by statusline.sh and guard.sh.
# Input: the status-line JSON Claude Code passes (rate_limits.seven_day).
# $now: epoch seconds. $base_day, $base: the day start and the week's percent
# used then, as recorded in ~/.claude/usage-guard-day. $last_at, $last_used:
# the status line's previous reading (~/.claude/usage-guard-last). When no
# figure is recorded for today, the day starts from the last reading taken
# before it began in this window, so usage before the first session of the day
# counts toward the day; failing that, from the current figure.
# The week is split into seven 24-hour days aligned to the window's start
# (resets_at minus 7 days). A day's budget is set when it begins: what was
# left of the week then, divided evenly over the days remaining, that day
# included. Usage during the day counts against the day, so a light day leaves
# more for each of the days after it, and a heavy day less.
# Output, or nothing when there is no current 7-day figure:
#   day         1-7, the day of the window now running
#   used        percent of the week used
#   day_start   epoch seconds when today began
#   day_ends    epoch seconds when today ends and the next day's budget opens
#   baseline    percent of the week used when today began
#   budget      today's budget, in percent of the week
#   spent       percent of the week used today
#   today       percent of today's budget used (100 when the budget is 0)
.rate_limits.seven_day as $w
| ($w.resets_at // 0) as $reset
| if $reset <= $now then empty else
    ($reset - 604800) as $start
  | ((($now - $start) / 86400 | floor) | if . < 0 then 0 elif . > 6 then 6 else . end) as $d
  | ($start + $d * 86400) as $day_start
  | ($w.used_percentage // 0) as $used
  | (if $base_day == $day_start then $base
     elif $last_at < $day_start and $last_at >= $start then $last_used
     else $used end) as $b
  | ((100 - $b) / (7 - $d)) as $budget
  | { day: ($d + 1),
      used: $used,
      day_start: $day_start,
      day_ends: ($day_start + 86400),
      baseline: $b,
      budget: $budget,
      spent: ($used - $b),
      today: (if $budget > 0 then ($used - $b) / $budget * 100 else 100 end) }
  end
