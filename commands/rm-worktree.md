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

Then interpret the output and respond **consistently** by case:

1. **No name was given** → show the list of worktrees as-is.
2. **Worktree was removed** (output says deleted/removed) → confirm which client
   and directory were removed.
3. **NOT removed because the workspace is dirty** (output contains
   `policy=keep` / "uncommitted work" / "open=" with a non-zero count) → do NOT
   just print manual `p4` commands. State how much pending work there is (open
   files + shelved CLs), then **ask the user to choose one**:
     - **shelve** — preserve the work as shelved changelists, then remove
     - **revert** — discard the work, then remove everything
     - **keep** — leave the worktree untouched
   When the user picks `shelve` or `revert`, re-run the same script with that
   policy: `"$script" <name> <policy>`. (Always offer this choice on a dirty
   workspace — never silently leave the user to figure out the next step.)

Only ever act on the named worktree; never remove anything else.
