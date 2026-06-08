#!/usr/bin/env bash
#
# p4-worktree-remove.sh — WorktreeRemove hook for Perforce.
#
# Claude Code calls this when an isolated worktree is being removed. It passes
# worktree_path (and worktree_name) on stdin.
#
# IMPORTANT limitation (by Claude Code design): WorktreeRemove has NO decision
# control. It cannot block removal, cannot prompt the user, and runs async.
# So "ask whether to shelve / revert / keep" is not possible here — we decide
# from a policy env var instead and log loudly to stderr.
#
#   P4_WORKTREE_ON_DIRTY = keep (default) | shelve | revert
#     keep   : if there are open or shelved files, do NOTHING destructive.
#              Leave the client and directory so no work is lost.
#     shelve : shelve open files (preserved server-side), revert to unlock,
#              remove the directory, KEEP the client (shelves live on it).
#     revert : DISCARD open files, delete the client, remove the directory.
#
# A clean workspace (no open/shelved files) is always fully removed.

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=p4-common.sh
. "$HERE/p4-common.sh"

INPUT="$(cat)"

POLICY="${P4_WORKTREE_ON_DIRTY:-keep}"

# p4 absence shouldn't error a hook that can't block anyway — just log.
command -v p4 >/dev/null 2>&1 || { warn "p4 not in PATH; skipping p4 cleanup."; exit 0; }

WT_PATH="$(jval worktree_path)"
WT_NAME="$(jval worktree_name)"
[ -n "$WT_PATH" ] || { warn "no worktree_path in input; nothing to clean up."; exit 0; }

# Resolve which client owns this worktree from the .p4config we wrote at create.
CFG_NAME="$(p4config_name)"
CLIENT=""
[ -f "$WT_PATH/$CFG_NAME" ] && CLIENT="$(sed -n 's/^P4CLIENT=//p' "$WT_PATH/$CFG_NAME" | head -n1)"
if [ -z "$CLIENT" ]; then
  warn "no P4CLIENT found in $WT_PATH/$CFG_NAME; leaving directory in place for safety."
  exit 0
fi

PORT="$(sed -n 's/^P4PORT=//p' "$WT_PATH/$CFG_NAME" | head -n1)"
[ -n "$PORT" ] && export P4PORT="$PORT"

log "removing worktree '$WT_NAME' (client=$CLIENT, policy=$POLICY)"

# ---- safety guards before we ever rm -rf ----------------------------------
remove_dir() {
  case "$WT_PATH" in
    ""|"/"|"$HOME"|"$HOME/") warn "refusing to delete suspicious path '$WT_PATH'."; return 0 ;;
  esac
  rm -rf "$WT_PATH" 2>/dev/null && log "removed directory $WT_PATH" \
    || warn "could not fully remove $WT_PATH (permissions?)."
}

delete_client() {
  if p4 client -d "$1" >&2 2>/dev/null; then
    log "deleted client $1"
  else
    warn "could not delete client $1 (may have shelved files or open files elsewhere)."
  fi
}

# ---- inspect the workspace state ------------------------------------------
OPENED_N="$(p4 -c "$CLIENT" opened 2>/dev/null | grep -c . || true)"
SHELVED_N="$(p4 -c "$CLIENT" changes -s shelved -c "$CLIENT" 2>/dev/null | grep -c . || true)"
log "open files: ${OPENED_N:-0}, shelved changelists: ${SHELVED_N:-0}"

if [ "${OPENED_N:-0}" -eq 0 ] && [ "${SHELVED_N:-0}" -eq 0 ]; then
  log "workspace is clean."
  delete_client "$CLIENT"
  remove_dir
  exit 0
fi

# ---- dirty workspace: apply policy ----------------------------------------
case "$POLICY" in
  keep)
    warn "workspace has uncommitted work (open=$OPENED_N shelved=$SHELVED_N)."
    warn "policy=keep: NOT deleting. Recover with: P4CLIENT=$CLIENT p4 opened / p4 changes -s shelved -c $CLIENT"
    warn "Re-run cleanup later with P4_WORKTREE_ON_DIRTY=shelve or =revert once you've handled the work."
    exit 0
    ;;
  shelve)
    # Preserve each NUMBERED pending changelist as its own shelf (keeps grouping
    # and descriptions), then shelve whatever is left in the default changelist
    # as one new list. Handles work spread across many changelists.
    for cl in $(p4 -c "$CLIENT" changes -s pending -c "$CLIENT" 2>/dev/null | awk '{print $2}'); do
      # Skip changelists with nothing open (e.g. already shelved) so we don't
      # error on "no files to shelve".
      [ -n "$(p4 -c "$CLIENT" opened -c "$cl" 2>/dev/null)" ] || continue
      if p4 -c "$CLIENT" shelve -f -c "$cl" >&2 2>/dev/null; then
        log "shelved changelist $cl (recover: p4 unshelve -s $cl)."
        p4 -c "$CLIENT" revert -c "$cl" //... >&2 2>/dev/null || true
      else
        warn "could not shelve changelist $cl; keeping workspace so nothing is lost."; exit 0
      fi
    done
    # Anything still open lives in the default changelist -> one new shelf for it.
    if [ -n "$(p4 -c "$CLIENT" opened 2>/dev/null)" ]; then
      CL="$(p4 -c "$CLIENT" change -o 2>/dev/null | p4 -c "$CLIENT" change -i 2>/dev/null | awk '{print $2}')"
      if [ -n "$CL" ] && p4 -c "$CLIENT" reopen -c "$CL" //... >&2 2>/dev/null \
                      && p4 -c "$CLIENT" shelve -c "$CL" >&2 2>/dev/null; then
        log "shelved default-changelist files into $CL (recover: p4 unshelve -s $CL)."
        p4 -c "$CLIENT" revert -c "$CL" //... >&2 2>/dev/null || true
      else
        warn "could not shelve remaining open files; keeping workspace."; exit 0
      fi
    fi
    # Shelves are tied to the client, so we keep the client but free the disk.
    remove_dir
    warn "kept client $CLIENT because it holds shelved work; delete it manually once unshelved."
    exit 0
    ;;
  revert)
    warn "policy=revert: DISCARDING all open files in $CLIENT (across every changelist)."
    p4 -c "$CLIENT" revert //... >&2 2>/dev/null || true
    # Drop any shelved changelists (delete the shelf, then the changelist).
    for cl in $(p4 -c "$CLIENT" changes -s shelved -c "$CLIENT" 2>/dev/null | awk '{print $2}'); do
      p4 -c "$CLIENT" shelve -d -c "$cl" >&2 2>/dev/null || true
      p4 -c "$CLIENT" change -d "$cl" >&2 2>/dev/null || true
    done
    # Delete any now-empty numbered pending changelists too, otherwise
    # `p4 client -d` is refused while the client still owns pending changes.
    for cl in $(p4 -c "$CLIENT" changes -s pending -c "$CLIENT" 2>/dev/null | awk '{print $2}'); do
      p4 -c "$CLIENT" change -d "$cl" >&2 2>/dev/null || true
    done
    delete_client "$CLIENT"
    remove_dir
    exit 0
    ;;
  *)
    warn "unknown P4_WORKTREE_ON_DIRTY='$POLICY'; treating as 'keep'. Not deleting."
    exit 0
    ;;
esac
