#!/bin/sh
# Removes what install.sh added from this clone: the statusLine entry (only if
# it points at this clone), the PreToolUse hook and the macOS LaunchAgent. The
# conf and state files stay unless --purge. Safe to run again.
usage() {
  cat <<'USAGE'
Usage: uninstall.sh [--purge]

  --purge   also delete ~/.claude/usage-guard.conf and the state, log and bypass files
USAGE
}
die() { echo "uninstall.sh: $*" >&2; exit 1; }
purge=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) purge=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
dir=$(cd "$(dirname "$0")" && pwd) || die "cannot resolve the clone's path"
command -v jq >/dev/null 2>&1 || die "jq is required"
settings="$HOME/.claude/settings.json"
sl="$dir/statusline.sh" guard="$dir/guard.sh"
stamp=$(date +%Y%m%d-%H%M%S)

if [ -f "$settings" ]; then
  jq -e 'type == "object"' "$settings" >/dev/null 2>&1 || die "$settings is not a JSON object; fix it and run again"
  new="$settings.new.$$"
  jq --arg sl "$sl" --arg g "$guard" '
    (if .statusLine.command? == $sl then del(.statusLine) else . end)
    | if .hooks.PreToolUse? then
        .hooks.PreToolUse |= (map(.hooks = ((.hooks // []) | map(select(.command != $g))))
                              | map(select((.hooks | length) > 0)))
        | (if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end)
        | (if (.hooks | length) == 0 then del(.hooks) else . end)
      else . end
  ' "$settings" > "$new" || { rm -f "$new"; die "could not edit $settings"; }
  if cmp -s "$new" "$settings"; then
    rm -f "$new"; echo "$settings holds nothing of this clone's"
  else
    cp "$settings" "$settings.bak-$stamp" || die "could not back up $settings"
    mv "$new" "$settings" || die "could not write $settings"
    echo "removed the status line and the hook from $settings (backup: $settings.bak-$stamp)"
  fi
fi

label=com.github.claude-usage-guard.probe
plist="$HOME/Library/LaunchAgents/$label.plist"
if [ -f "$plist" ]; then
  [ "${USAGE_GUARD_SKIP_LAUNCHCTL:-}" = 1 ] || launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1
  rm -f "$plist"
  echo "removed the LaunchAgent $label"
fi
[ "$(uname -s)" = Darwin ] || echo "If you added the probe to your crontab, remove that line (crontab -e)."

c="$HOME/.claude"
if [ "$purge" -eq 1 ]; then
  rm -rf "$c/usage-guard.conf" "$c/usage-guard.json" "$c/usage-guard-last" "$c/usage-guard-day" \
    "$c/usage-guard-bypass" "$c/usage-guard-bypass.log" "$c/usage-guard-probe.log" \
    "$c/usage-guard-probe.err" "$c/usage-guard-probe.d"
  echo "purged the conf, state and log files"
else
  echo "kept $c/usage-guard.conf and the state files (--purge deletes them)"
fi
echo "done."
