#!/usr/bin/env bash
# p4-common.sh — shared helpers for the Perforce worktree hooks.
# Sourced by p4-worktree-create.sh, p4-worktree-remove.sh, p4-session-start.sh.
#
# Design notes:
#  - All informational logging goes to STDERR. The WorktreeCreate hook must
#    print ONLY the worktree path on STDOUT (Claude Code cd's into whatever it
#    prints), so nothing else may touch stdout.
#  - p4 config on this machine lives in a P4ENVIRO/P4CONFIG file, not exported
#    env vars, so we resolve P4CLIENT/P4PORT/P4USER via `p4 set` as a fallback.

# ---- logging (stderr only) -------------------------------------------------
log()  { printf '[p4-worktree] %s\n' "$*" >&2; }
warn() { printf '[p4-worktree] WARN: %s\n' "$*" >&2; }
die()  { printf '[p4-worktree] ERROR: %s\n' "$*" >&2; exit 1; }

# ---- preflight: p4 must exist ----------------------------------------------
require_p4() {
  command -v p4 >/dev/null 2>&1 || die "p4 not found in PATH. Install Helix CLI or fix PATH."
}

# ---- resolve a p4 variable: prefer real env var, else `p4 set` --------------
# Usage: val=$(p4val P4CLIENT)
p4val() {
  local name="$1" v
  v="${!name:-}"
  if [ -n "$v" ]; then
    printf '%s' "$v"
    return 0
  fi
  # `p4 set` annotates the source, e.g.
  #   P4CONFIG=.p4config (enviro) (config 'noconfig')
  # Strip "name=" and everything from the first " (" annotation onward.
  p4 set "$name" 2>/dev/null \
    | sed -E "s/^${name}=//; s/[[:space:]]+\(.*$//" \
    | head -n1
}

# ---- read a string field from the hook's JSON stdin ------------------------
# $INPUT must already hold the full stdin payload. Prefers python3, falls back
# to a sed extractor for flat string fields.
jval() {
  local key="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get(sys.argv[1], ""))
except Exception:
    pass
' "$key" 2>/dev/null
  else
    printf '%s' "$INPUT" \
      | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      | head -n1
  fi
}

# ---- sanitize a string into a valid p4 client-name fragment ----------------
# p4 client names can't contain spaces or @ # * % / ; we map anything outside
# [A-Za-z0-9_.-] to underscore.
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }

# ---- name of the per-worktree p4 config file -------------------------------
p4config_name() {
  local n; n="$(p4val P4CONFIG)"
  [ -n "$n" ] && printf '%s' "$n" || printf '%s' ".p4config"
}
