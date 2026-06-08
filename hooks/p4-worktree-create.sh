#!/usr/bin/env bash
#
# p4-worktree-create.sh — WorktreeCreate hook for Perforce.
#
# Claude Code calls this when it wants a new isolated worktree, passing a JSON
# payload on stdin (a worktree name; for non-git worktrees it may NOT include a
# directory). Our job:
#
#   1. Resolve the current (base) client spec from the environment.
#   2. Pick a collision-safe sibling client name "<base>-claude-<name>".
#   3. Decide the worktree directory (use the payload's path if given, else
#      choose a sibling of the project dir) and set the client Root to it.
#   4. Sync it to the same changelist the base client is synced to (from the
#      depot — uncommitted local work in the base workspace is NOT copied).
#   5. Drop a .p4config in the worktree root so the new P4CLIENT is used there.
#   6. Print ONLY the worktree path on stdout so Claude cd's into it.
#
# Contract reminders:
#   - stdout must contain nothing but the final path.
#   - Any non-zero exit aborts worktree creation; stderr is shown to the user.
#   - CLAUDE_ENV_FILE is NOT available here, so P4CLIENT is exported into the
#     session by the companion SessionStart hook (p4-session-start.sh), which
#     reads the .p4config we write below.

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=p4-common.sh
. "$HERE/p4-common.sh"

INPUT="$(cat)"

require_p4

# ---- inputs from Claude Code ----------------------------------------------
# Non-git worktree payload field names aren't well documented, so try several
# and fall back. For a name, accept worktree_name/name/worktree_id/session_id.
WT_NAME="$(jval worktree_name)"
[ -n "$WT_NAME" ] || WT_NAME="$(jval name)"
[ -n "$WT_NAME" ] || WT_NAME="$(jval worktree_id)"
[ -n "$WT_NAME" ] || WT_NAME="$(jval session_id)"
[ -n "$WT_NAME" ] || WT_NAME="wt-$(date +%s)"

# For the directory, accept worktree_path/path/worktree_dir if Claude supplies
# one. Otherwise WE choose it, as a sibling of the PROJECT ROOT (the dir holding
# .claude, via $CLAUDE_PROJECT_DIR) — NOT the launch cwd. This makes placement:
#   - identical no matter which subdir you launch from, and
#   - OUTSIDE the base client's root (never nest a p4 client root inside another).
# Because that puts the worktree outside the repo tree, we later symlink .claude
# into it so the worktree session still finds the hooks and /rm-worktree.
WT_PATH="$(jval worktree_path)"
[ -n "$WT_PATH" ] || WT_PATH="$(jval path)"
[ -n "$WT_PATH" ] || WT_PATH="$(jval worktree_dir)"
if [ -z "$WT_PATH" ]; then
  PROJ="${CLAUDE_PROJECT_DIR:-}"
  [ -n "$PROJ" ] || PROJ="$(jval cwd)"
  [ -n "$PROJ" ] || PROJ="$PWD"
  WT_PATH="$(dirname "$PROJ")/$(basename "$PROJ")-$(sanitize "$WT_NAME")"
  log "no path in payload; chose worktree dir: $WT_PATH"
fi

# ---- resolve base p4 coordinates ------------------------------------------
BASE_CLIENT="$(p4val P4CLIENT)"
P4PORT_V="$(p4val P4PORT)"
P4USER_V="$(p4val P4USER)"
[ -n "$BASE_CLIENT" ] || die "P4CLIENT is not set (env or 'p4 set'). Cannot clone a base workspace."
[ -n "$P4PORT_V" ]   || die "P4PORT is not set (env or 'p4 set'). Set it to host:port and retry."
export P4PORT="$P4PORT_V"
[ -n "$P4USER_V" ] && export P4USER="$P4USER_V"

# Verify the base client actually exists / we can reach the server.
if ! p4 clients -e "$BASE_CLIENT" 2>/dev/null | grep -q .; then
  die "base client '$BASE_CLIENT' not found on $P4PORT_V (check login: 'p4 login', and P4CLIENT)."
fi

# ---- choose a collision-safe client name -----------------------------------
# Perforce client names are GLOBAL (not per-user). So before creating, check
# whether the desired name is taken:
#   - free                              -> use it
#   - owned by us, rooted at this path  -> reuse it (resume case)
#   - owned by someone else, or ours    -> never clobber: append -1, -2, ...
#     but rooted elsewhere
DESIRED="$(sanitize "${BASE_CLIENT}-claude-${WT_NAME}")"
NEW_CLIENT=""
cand="$DESIRED"; i=0
while :; do
  if ! p4 clients -e "$cand" 2>/dev/null | grep -q .; then
    NEW_CLIENT="$cand"; break                       # name is free
  fi
  owner="$(p4 client -o "$cand" 2>/dev/null | awk '/^Owner:/{print $2; exit}')"
  croot="$(p4 client -o "$cand" 2>/dev/null | awk '/^Root:/{ $1="";sub(/^[ \t]+/,"");print;exit}')"
  if [ "$owner" = "$P4USER_V" ] && { [ "$croot" = "$WT_PATH" ] || [ -z "$croot" ]; }; then
    NEW_CLIENT="$cand"; log "reusing existing client '$cand' (yours, same root)."; break
  fi
  if [ "$owner" != "$P4USER_V" ]; then
    warn "client name '$cand' already exists and is owned by '$owner'; trying another."
  else
    warn "client '$cand' is yours but rooted at '$croot'; trying another to avoid clobbering it."
  fi
  i=$((i+1)); cand="${DESIRED}-${i}"
  [ "$i" -le 50 ] || die "no free client name based on '$DESIRED' after 50 tries."
done

log "base client     : $BASE_CLIENT"
log "new client      : $NEW_CLIENT"
log "worktree path   : $WT_PATH"

# ---- create the worktree directory ----------------------------------------
mkdir -p "$WT_PATH" 2>/dev/null || die "cannot create worktree dir '$WT_PATH' (permissions?)."

# ---- create/refresh the new client templated from the base -----------------
# `p4 client -o -t BASE NEW` emits a spec whose View is already rewritten to
# //.../ NEW; we only override Root and clear Host so the client isn't pinned to
# one machine. Errors here must abort creation.
if ! p4 client -o -t "$BASE_CLIENT" "$NEW_CLIENT" \
      | awk -v root="$WT_PATH" '
          /^Root:/ { print "Root:\t" root; next }
          /^Host:/ { print "Host:";        next }
          { print }
        ' \
      | p4 client -i >&2; then
  die "failed to create client '$NEW_CLIENT' (server/permission error)."
fi

# ---- figure out the changelist the base client is synced to ----------------
SYNC_CL="$(p4 changes -m1 "@${BASE_CLIENT}" 2>/dev/null | awk '{print $2}')"
if [ -n "$SYNC_CL" ]; then
  log "syncing to base changelist @$SYNC_CL"
  SYNC_REV="@${SYNC_CL}"
else
  warn "could not determine base changelist; syncing new client to #head."
  SYNC_REV=""
fi

# ---- sync the new client ---------------------------------------------------
# A hard sync failure aborts so Claude never cd's into a broken workspace; we
# tear down the half-created client first.
if ! p4 -c "$NEW_CLIENT" sync ${SYNC_REV:+"$SYNC_REV"} >&2; then
  warn "sync failed; rolling back client '$NEW_CLIENT'."
  p4 client -d "$NEW_CLIENT" >&2 2>/dev/null || true
  die "p4 sync failed for '$NEW_CLIENT' (disk space, view, or permissions)."
fi

# ---- write per-worktree p4 config so the new client is used in that dir ----
CFG_NAME="$(p4config_name)"
{
  printf 'P4CLIENT=%s\n' "$NEW_CLIENT"
  printf 'P4PORT=%s\n'   "$P4PORT_V"
  [ -n "$P4USER_V" ] && printf 'P4USER=%s\n' "$P4USER_V"
} > "$WT_PATH/$CFG_NAME" 2>/dev/null \
  || warn "could not write $CFG_NAME in worktree (P4CLIENT will still be set via SessionStart)."

# ---- make the project's .claude reachable from the worktree session --------
# The worktree session roots at WT_PATH, which is OUTSIDE the project tree, so
# Claude's walk-up would never reach the project's .claude (hooks + commands).
# Symlinking it in fixes SessionStart binding and the /rm-worktree command.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR/.claude" ] && [ ! -e "$WT_PATH/.claude" ]; then
  ln -s "$CLAUDE_PROJECT_DIR/.claude" "$WT_PATH/.claude" 2>/dev/null \
    && log "linked .claude into worktree (hooks + /rm-worktree available there)." \
    || warn "could not link .claude into worktree; /rm-worktree won't load in it."
fi

log "worktree ready. P4CLIENT for this session will be: $NEW_CLIENT"

# ---- the ONE thing on stdout: the path Claude cd's into --------------------
printf '%s\n' "$WT_PATH"
