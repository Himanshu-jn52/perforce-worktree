#!/usr/bin/env bash
#
# p4-worktree-rm.sh — manually remove a Perforce worktree created by the hooks.
# There is no built-in "claude worktree remove" command for custom (non-git)
# worktrees, so use this.
#
# Usage:
#   p4-worktree-rm.sh                 # list all *-claude-* worktrees + state
#   p4-worktree-rm.sh <name>          # remove worktree <name> (keep policy)
#   p4-worktree-rm.sh <name> revert   # discard open files, then remove
#   p4-worktree-rm.sh <name> shelve   # shelve open files, then remove dir
#
# <name> may be either the full client name (e.g.
# p4python_ws_100_commits-claude-update-client-test) or just the suffix you
# passed to `claude --worktree <name>` (e.g. update-client-test).

set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/p4-common.sh"
INPUT=""
require_p4

if [ $# -eq 0 ]; then
  echo "Perforce worktrees (clients matching *-claude-*):"
  echo
  p4 clients -e '*-claude-*' 2>/dev/null | while read -r _ client _ _ root _; do
    opened="$(p4 -c "$client" opened 2>/dev/null | grep -c . || true)"
    shelved="$(p4 -c "$client" changes -s shelved -c "$client" 2>/dev/null | grep -c . || true)"
    printf '  %-55s open=%s shelved=%s\n      root: %s\n' "$client" "${opened:-0}" "${shelved:-0}" "$root"
  done
  echo
  echo "Remove one with:  $(basename "$0") <name> [keep|shelve|revert]"
  exit 0
fi

ARG="$1"
POLICY="${2:-keep}"

# Resolve ARG to an actual client. Accept an exact client name, the worktree
# suffix (*-claude-<arg>), or a substring match — whichever hits a real client.
# We never reconstruct from the *current* P4CLIENT (which may itself be a
# worktree client when run from inside one), to avoid double-prefixing.
CLIENT=""
if p4 clients -e "$ARG" 2>/dev/null | grep -q .; then
  CLIENT="$ARG"
else
  CLIENT="$(p4 clients -e "*-claude-${ARG}" 2>/dev/null | awk 'NR==1{print $2}')"
  [ -n "$CLIENT" ] || CLIENT="$(p4 clients -e "*${ARG}*" 2>/dev/null | awk '/-claude-/{print $2; exit}')"
fi
[ -n "$CLIENT" ] || die "no client matching '$ARG'. Run with no args to list worktrees."

# Derive a stable worktree name (suffix after -claude-) for the remove hook.
NAME="${CLIENT##*-claude-}"

# Read Root from the spec, not the `p4 clients` text line (whose trailing
# description can contain quotes/spaces and corrupt a regex scrape).
ROOT="$(p4 client -o "$CLIENT" 2>/dev/null | awk '/^Root:/{ $1=""; sub(/^[ \t]+/,""); print; exit }')"
[ -n "$ROOT" ] || die "client '$CLIENT' found but could not read its Root."

# Hand off to the real remove hook so policy/safety logic stays in one place.
printf '{"worktree_path":"%s","worktree_name":"%s"}\n' "$ROOT" "$NAME" \
  | P4_WORKTREE_ON_DIRTY="$POLICY" "$HERE/p4-worktree-remove.sh"
