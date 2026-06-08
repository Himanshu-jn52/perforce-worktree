#!/usr/bin/env bash
#
# p4-session-start.sh — SessionStart hook.
#
# WorktreeCreate cannot set P4CLIENT for the session (no CLAUDE_ENV_FILE there).
# SessionStart CAN: anything written to $CLAUDE_ENV_FILE is exported into every
# Bash tool command for the rest of the session. So when a session starts inside
# a worktree we created, we read the P4CLIENT out of the worktree's .p4config and
# export it here. This is what actually isolates the session's p4 operations.
#
# Safe to run in non-worktree sessions: if there's no .p4config, it does nothing.

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=p4-common.sh
. "$HERE/p4-common.sh"

INPUT="$(cat)"

# Where did the session start? Prefer the cwd Claude passes in, else project dir.
CWD="$(jval cwd)"
[ -n "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"

CFG_NAME="$(command -v p4 >/dev/null 2>&1 && p4config_name || echo .p4config)"
CFG="$CWD/$CFG_NAME"

[ -f "$CFG" ] || { log "no $CFG_NAME in $CWD; not a p4 worktree session, nothing to do."; exit 0; }

CLIENT="$(sed -n 's/^P4CLIENT=//p' "$CFG" | head -n1)"
[ -n "$CLIENT" ] || { warn "$CFG has no P4CLIENT line; leaving session env unchanged."; exit 0; }

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    printf 'export P4CLIENT=%q\n' "$CLIENT"
    PORT="$(sed -n 's/^P4PORT=//p' "$CFG" | head -n1)"
    [ -n "$PORT" ] && printf 'export P4PORT=%q\n' "$PORT"
    USER_V="$(sed -n 's/^P4USER=//p' "$CFG" | head -n1)"
    [ -n "$USER_V" ] && printf 'export P4USER=%q\n' "$USER_V"
  } >> "$CLAUDE_ENV_FILE"
  log "session bound to isolated workspace P4CLIENT=$CLIENT"
else
  warn "CLAUDE_ENV_FILE not available; P4CLIENT not exported. Rely on $CFG_NAME via P4CONFIG instead."
fi

# Surface the binding to Claude as session context too.
cat <<JSON
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Perforce worktree isolation active: this session uses P4CLIENT=$CLIENT. Run p4 commands normally; they affect only this isolated workspace."}}
JSON
