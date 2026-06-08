---
description: Remove a Perforce worktree (p4 client + directory) created by the worktree hooks
argument-hint: <worktree-name-or-client> [keep|shelve|revert]
allowed-tools: Bash
---

The user wants to remove the Perforce worktree: **$ARGUMENTS**

Run the following with the Bash tool. It walks up from the current directory to
find `p4-worktree-rm.sh` (don't rely on $CLAUDE_PROJECT_DIR — it isn't set for
Bash calls), then runs it. With NO arguments it lists worktrees instead of
deleting. The argument may be a full client name or just the worktree suffix.

```bash
d="$PWD"; script=""
while :; do
  for c in "$d/.claude/hooks/p4-worktree-rm.sh" "$d/main/.claude/hooks/p4-worktree-rm.sh"; do
    [ -x "$c" ] && { script="$c"; break 2; }
  done
  [ "$d" = "/" ] && break
  d="$(dirname "$d")"
done
[ -n "$script" ] || { echo "p4-worktree-rm.sh not found (searched up from $PWD)"; exit 1; }
"$script" $ARGUMENTS
```

Then report concisely: which p4 client and directory were removed, or (with the
`keep` policy on a dirty workspace) what was preserved and how to recover it, or
the list of worktrees if no name was given. Do not delete anything other than
the named worktree.
