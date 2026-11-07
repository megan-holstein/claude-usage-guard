# claude-usage-guard

claude-usage-guard stops Claude Code from starting new subagents once your subscription usage reaches a limit, while the work already running finishes. On Claude Ultra, it also paces the week in daily budgets, recalculated at the start of each day as the week's remaining usage divided by the days left, and shows how much of today's budget you have used.

Status: published as-is. Issues and pull requests are welcome. There is no support and no compatibility promise.

## Requirements

- Claude Code, logged in with a claude.ai subscription (Pro, Max or Ultra). Claude Code passes `rate_limits` to the status line only for subscribers, so API-key logins show nothing for the guard to read.
- `jq`.
- macOS or Linux. The scripts are POSIX `sh` and fall back between BSD and GNU `stat` and `date`.
- Only for the optional day-start probe: `claude` on your `PATH`, and launchd (macOS) or cron (Linux).

## Install

```sh
git clone https://github.com/megan-holstein/claude-usage-guard.git
cd claude-usage-guard
./install.sh --plan max        # or pro, or ultra
```

`install.sh` is safe to run again. It:

- writes `~/.claude/usage-guard.conf` with `plan=<your plan>` (`--plan` is required on the first install);
- backs up `~/.claude/settings.json` with a timestamp (`settings.json.bak-YYYYMMDD-HHMMSS`), then merges in a `statusLine` entry (`refreshInterval: 60`) and a `PreToolUse` hook with the matcher `Agent|Workflow`, both pointing at scripts in the clone;
- refuses to replace a different `statusLine` that already exists, unless you pass `--force` (the old one stays in the backup);
- on Claude Ultra, schedules the day-start probe (see [The probe](#the-probe)).

Options: `--probe-time HH:MM`, `--no-probe`, `--force`. Keep the clone where it is: `settings.json` points at its absolute path. To move it, run `./uninstall.sh` first, move the clone, and install again. Restart Claude Code (or open a new session) after installing.

## Uninstall

```sh
./uninstall.sh            # removes the statusLine (only if it points at this clone), the hook and the LaunchAgent
./uninstall.sh --purge    # also deletes the conf, state and log files
```

On Linux, remove the crontab line yourself if you added one.

## The plans

`~/.claude/usage-guard.conf` holds `plan=pro`, `plan=max` or `plan=ultra`. The default is `max`.

| Plan | Enforced | Status line |
|---|---|---|
| Claude Pro (`pro`) | the 5-hour window and the weekly window, each at 90% | `pro · 5h 12% · 7d 34%` |
| Claude Max (`max`) | the same | `max · 5h 12% · 7d 34%` |
| Claude Ultra (`ultra`) | the weekly window at 90%, and the day's budget at 90% | `ultra · 7d 2% · day 4/7 · today 1% of 25% budget used` |

Change the plan by editing the `plan=` line.

## The daily budget (Claude Ultra)

The weekly window is split into seven 24-hour days, counted back from the window's reset time (`rate_limits.seven_day.resets_at`). A day begins at the reset's time of day. A day's budget is set when the day begins:

```
budget = (100 - weekly % used when the day began) / (days remaining, including that day)
```

Worked example: day 4 of 7 begins with 1% of the week used. Four days remain, counting day 4, so the budget is (100 - 1) / 4 = 24.75% of the week. The status line shows it rounded: `ultra · 7d 2% · day 4/7 · today 1% of 25% budget used`, where `today 1%` is the share of the week used since the day began and `25%` is the budget, both in percent of the week. The guard refuses new subagents once today's usage reaches 90% of the budget, here 22.3% of the week.

Usage during a day counts against that day only. A light day raises the budget of every day after it, and a heavy day lowers it. A day that begins with the weekly window used up has no budget, and the guard refuses until the next day opens.

The status line turns yellow at 75% of the day's budget (`daily_warn`) and red at the guard's limit (`daily`).

The day's starting figure is the last status-line reading taken before the day began (kept in `~/.claude/usage-guard-last`), recorded in `~/.claude/usage-guard-day` the first time the status line runs in the new day. Usage between that last reading and the day's start (on claude.ai, for example) counts toward the new day, which errs toward stopping early. A last reading from a previous weekly window is ignored; the day then starts from the current figure.

## Configuration

Keys in `~/.claude/usage-guard.conf`, one `key=value` per line, `#` starts a comment:

| Key | Default | Meaning |
|---|---|---|
| `plan` | `max` | `pro`, `max` or `ultra` |
| `five_hour` | `90` | percent of the 5-hour window at which launches are refused (`pro`, `max`) |
| `seven_day` | `90` | percent of the weekly window (every plan) |
| `daily` | `90` | percent of the day's budget (`ultra`) |
| `daily_warn` | `75` | percent of the day's budget at which the status line turns yellow (`ultra`) |
| `probe_time` | derived | local time the day-start probe runs, `HH:MM` (`ultra`); written by `install.sh` |

Any limit also accepts `off`, which disables that check: `daily=off`. Delete a line to return to its default.

## Bypass

To work past a limit on purpose, touch one of two flag files, in any terminal or with a `!` command at the Claude Code prompt (a `!` command runs outside any tool call, so the guard does not block it):

- `! touch ~/.claude/usage-guard-bypass` opens the guard for 30 minutes (`USAGE_GUARD_BYPASS_TTL` seconds, default 1800).
- `! touch ~/.claude/usage-guard-bypass-today` opens it for the rest of the day. On `ultra` the day is the budget day, so the flag lasts until the next day's budget opens; on `pro` and `max` it is the local calendar day, and the flag lasts until midnight.

Each flag expires on its own, so a forgotten one does not leave the guard open. While a flag is open, the status line ends with `· guard open until HH:MM`. Launching Claude Code with `USAGE_GUARD_BYPASS=1` bypasses the guard for that session. Each bypassed launch appends a line to `~/.claude/usage-guard-bypass.log`. Delete the flag files to restore the guard.

An agent never sets a flag. The refusal message instructs the agent to end its reply with both `! touch` lines, so you can run the one you want.

## The probe

The status line records usage only while a Claude Code session runs. On `ultra`, a day's budget starts from the last reading before the day began, so if no session was open overnight, that reading can be hours old. The probe fixes that: once a day, a minute before the day begins, `probe.sh` sends one headless request, `claude -p ok --model haiku --setting-sources project --no-session-persistence --output-format stream-json --verbose`, reads `rate_limit_event.rate_limit_info.unifiedWindows.seven_day.utilization` from the output, and writes it to `~/.claude/usage-guard-last`. The run is logged to `~/.claude/usage-guard-probe.log`.

- **Cost:** one small Haiku request a day. It counts against your usage by a negligible amount.
- **Time:** `install.sh` computes the probe time as one minute before the weekly reset's time of day, read from `~/.claude/usage-guard.json` (the status line writes it). Before any session has recorded a reset, pass `--probe-time HH:MM`; without it, the installer uses 00:59 and prints a note. Re-run `./install.sh` after your first session to derive the real time. The time is stored as `probe_time` in the conf, and `probe.sh` reads it from there.
- **macOS:** `install.sh` writes `~/Library/LaunchAgents/com.github.claude-usage-guard.probe.plist` (a `StartCalendarInterval` job) and loads it with `launchctl bootstrap`. Set `USAGE_GUARD_SKIP_LAUNCHCTL=1` to write it without loading.
- **Linux:** `install.sh` prints a crontab line (`M H * * * /path/to/probe.sh`) for you to add with `crontab -e`.
- **Sleep and shutdown:** launchd runs a job missed during sleep once the Mac wakes, and skips one missed during a shutdown. A late run sends nothing: a reading taken after the day began includes that day's usage, so the day keeps starting from the last reading before it. cron skips jobs missed while the machine is off or asleep.
- **Daylight saving time:** the probe time is a local clock time, but the reset is a fixed instant, so a clock change moves the reset's time of day by an hour. When the probe runs on time and finds the day starting at a different time, it sends nothing and logs `skipped: the day now starts at HH:MM` to `~/.claude/usage-guard-probe.log`. Re-run `./install.sh` to derive the new time (the status line has recorded the new reset by then).
- `claude -p` cannot run with `--bare`, which skips the Keychain read that holds the login.

Skip the probe with `./install.sh --no-probe`. The guard still works; it starts each day from the last status-line reading.

## What the status line shows

- `pro`, `max`: `max · 5h NN% · 7d NN%`, the usage of each window.
- `ultra`: `ultra · 7d NN% · day N/7 · today NN% of NN% budget used`. `7d` is the week's usage, `day N/7` the day of the window now running, and the last two figures the share of the week used today and today's budget, in percent of the week. On a day with no budget it reads `no budget left today`.
- Claude Code sends a session no usage figure until its first response, so a new window shows the last figure any session recorded (`~/.claude/usage-guard.json`) from the moment it opens, and keeps that file intact for the guard. Usage elsewhere since then (claude.ai, another device) appears after the first response. A window that has reset since, or a figure never recorded, shows as `?`.

`refreshInterval: 60` makes Claude Code re-run the status line every minute, so the figure stays current while a session sits idle with agents running in the background. Without it, background agents can reach the hard cap before the guard sees 90%.

## A snippet for your agent instructions

Paste this into your `CLAUDE.md` or `AGENTS.md` so every agent behaves the same way when the guard refuses:

```markdown
## Usage guard

A hook refuses new subagent launches (the Agent and Workflow tools) once a usage limit is reached. When it refuses:

- Launch no new subagent and start no new task. Finish, verify, commit and push the work already in flight; resume a stopped subagent with SendMessage if its task is unfinished.
- Schedule a wakeup for the reset time the refusal names (ScheduleWakeup in steps of up to an hour, or a one-shot cron job), and retry the refused launch when it fires.
- Never create a bypass flag yourself. Say where things stand, and end your reply with these two lines, verbatim, so the user can open the guard sooner, for 30 minutes or for the rest of the day:
  `! touch ~/.claude/usage-guard-bypass`
  `! touch ~/.claude/usage-guard-bypass-today`
- Tell each subagent to commit and push at every checkpoint, so a task that hits the hard cap stays resumable.
```

## Limitations

- Claude Code reports usage in whole percent, so the guard works at that resolution: a 90% limit trips when the reported figure reads 90.
- The figure refreshes only while a session runs or the probe fires. Right after a window resets, the saved figure can show the old percentage for up to a minute, until the next refresh.
- The guard refuses new launches only. It does not stop subagents that are already running, and one of them can still reach the account's hard cap at 100%, which ends it mid-call.
- The hook reads the figure the status line recorded; with no status line installed, or before any session has recorded a figure, the guard passes everything.
- Day boundaries are 24-hour chunks counted from the weekly reset, so across a daylight saving change they shift on the local clock.
- On `pro` and `max`, on the day of a daylight saving change the status line's `guard open until` time is off by an hour; the rest-of-day flag itself still expires at midnight.

## Development

`sh tests/run.sh` runs the suite against a temporary `HOME` with synthetic status-line JSON; it needs `sh` and `jq` and touches nothing outside the temporary directory. CI runs it on Ubuntu and macOS, and runs ShellCheck on Ubuntu.

## License

MIT. See `LICENSE`.
