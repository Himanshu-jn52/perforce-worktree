# Perforce worktree isolation for Claude Code

Run multiple [Claude Code](https://claude.com/claude-code) sessions in parallel,
each in its own isolated **Perforce workspace** — so edits, syncs, and pending
changelists in one session never collide with another.

It's the equivalent of `git worktree`, but for Perforce (which has no native
worktree concept). Claude Code's `--worktree` flag normally creates a *git*
worktree; this project plugs custom hooks into that same flow so it creates and
tears down a **p4 client** instead.

```
$ claude --worktree feature-login
   → creates client  myws-claude-feature-login
   → syncs a fresh tree at  ../myproject-feature-login
   → drops you into a session bound to that client
$ /rm-worktree feature-login      # when you're done
   → reverts/cleans, deletes the client and the directory
```

---

## Requirements

- **Claude Code** (with worktree support — the `--worktree` flag and `WorktreeCreate`/`WorktreeRemove`/`SessionStart` hooks).
- **Perforce CLI** (`p4`) on your `PATH`, logged in (`p4 login`).
- `P4PORT`, `P4USER`, `P4CLIENT` resolvable from your environment or `p4 set` / `P4CONFIG` / `P4ENVIRO`.
- Permission to create clients and `write` access to your base client's depot paths.

---

## Install

These hooks must live in the **`.claude/` at your project root** (the common
ancestor of every worktree). From the root of your Perforce-backed project:

```bash
# from the repo root of this project
mkdir -p .claude/hooks .claude/commands

# copy the hook scripts and the slash command into place
cp hooks/*.sh        .claude/hooks/
cp commands/*.md     .claude/commands/
chmod +x .claude/hooks/*.sh
```

Then add the hook registration to `.claude/settings.json` (merge into your
existing file if you have one):

```json
{
  "hooks": {
    "WorktreeCreate": [
      { "hooks": [ { "type": "command",
        "command": "\"$CLAUDE_PROJECT_DIR/.claude/hooks/p4-worktree-create.sh\"" } ] }
    ],
    "WorktreeRemove": [
      { "hooks": [ { "type": "command",
        "command": "\"$CLAUDE_PROJECT_DIR/.claude/hooks/p4-worktree-remove.sh\"" } ] }
    ],
    "SessionStart": [
      { "hooks": [ { "type": "command",
        "command": "\"$CLAUDE_PROJECT_DIR/.claude/hooks/p4-session-start.sh\"" } ] }
    ]
  }
}
```

**Restart Claude Code** so it loads the new hooks and the `/rm-worktree` command.
(A newly created `.claude/commands/` directory is only picked up on restart.)

> A copy of `settings.json` with these hooks is included in this repo as a
> starting point.

---

## Usage

### 1. Create an isolated worktree

```bash
claude --worktree <name>
```

This fires the `WorktreeCreate` hook, which:

1. reads your current client as the **base**,
2. creates a sibling client `‹base›-claude-‹name›`,
3. syncs it to the same changelist as the base (from the depot),
4. starts the session **inside** the new worktree directory.

You can run several at once — `claude --worktree api`, `claude --worktree ui` —
and they stay completely isolated.

### 2. Work as normal

Inside the session, every `p4` command (and every file edit) targets the
isolated client automatically — `P4CLIENT` is bound for you by the
`SessionStart` hook. Verify any time with:

```bash
p4 set P4CLIENT      # → ‹base›-claude-‹name›
```

### 3. Remove a worktree when done

There is **no built-in** Claude command to remove a worktree, and simply exiting
the session does **not** remove it (your work is preserved). Remove it
explicitly with the slash command:

```
/rm-worktree                 # list all worktrees + their open/shelved counts
/rm-worktree <name>          # remove it (safe: refuses if there's pending work)
/rm-worktree <name> shelve   # shelve pending work to the server, then remove the dir
/rm-worktree <name> revert   # discard pending work, then remove everything
```

`<name>` can be the short name you used with `--worktree`, or the full client name.

Equivalent without the slash command:

```bash
.claude/hooks/p4-worktree-rm.sh                 # list
.claude/hooks/p4-worktree-rm.sh <name> [policy] # remove
```

---

## Configuration

| Env var | Default | What it controls |
| --- | --- | --- |
| `P4_WORKTREE_ON_DIRTY` | `keep` | What removal does when the workspace has **uncommitted or shelved** work. |

| Policy | Behavior on a dirty workspace |
| --- | --- |
| `keep` (default) | Do nothing destructive — leaves the client and files intact, logs how to recover. **Never loses work.** |
| `shelve` | Shelve open files to the server, revert to unlock, remove the directory, keep the client (so the shelf survives). |
| `revert` | Discard open files, delete shelved changelists, delete the client and directory. **Destructive — opt in.** |

A clean workspace (nothing open or shelved) is always fully removed regardless of policy.

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `/rm-worktree` doesn't appear | The `.claude/commands/` dir was added after launch — **restart Claude Code**. Also ensure `.claude/` is at the project root, not a subfolder. |
| Hooks don't fire / create aborts immediately | Not logged in — run `p4 login`. The hook aborts with a clear message if the ticket is missing. |
| `P4CLIENT is not set` on create | `p4 set P4CLIENT` / `P4PORT` must resolve. Run `p4 set` to confirm. |
| Worktree session has no `/rm-worktree` | Worktrees are placed outside the repo; the create hook symlinks `.claude` into each so commands resolve. If missing, re-run create or `ln -s <repo>/.claude <worktree>/.claude`. |
| Worktree creation fails with a name clash | The client name is taken by another user. The hook auto-appends `-1`, `-2`, … and never modifies a client you don't own. |

---

## How it works (design notes)

The scripts in `hooks/`:

| Script | Hook | Role |
| --- | --- | --- |
| `p4-worktree-create.sh` | `WorktreeCreate` | Create a collision-safe client, sync it, write `.p4config`, symlink `.claude` in, print the path. |
| `p4-session-start.sh` | `SessionStart` | Read `.p4config` and export `P4CLIENT` into the session (the only point where this is possible). |
| `p4-worktree-remove.sh` | `WorktreeRemove` | Inspect for open/shelved work and clean up per `P4_WORKTREE_ON_DIRTY`. |
| `p4-worktree-rm.sh` | — | Manual list/remove helper; backs `/rm-worktree`. |
| `p4-common.sh` | — | Shared helpers (logging, p4-var resolution, JSON parsing). |

A few non-obvious decisions, for the curious:

- **Three hooks, not two.** `WorktreeCreate` can't set `P4CLIENT` for the new
  session (a hook subprocess can't change the parent's environment), so it writes
  a `.p4config` and the `SessionStart` hook does the binding.
- **Worktrees live outside the repo.** A p4 client root must never be nested
  inside another client's root, so worktrees are placed as a sibling of the
  project root. Because Claude discovers config by walking *up* the tree (never
  into siblings), the create hook **symlinks `.claude`** into each worktree so the
  hooks and `/rm-worktree` still resolve.
- **Removal can't prompt.** `WorktreeRemove` runs async and can't block or ask
  questions, so the dirty-workspace behavior is the `P4_WORKTREE_ON_DIRTY` policy
  instead of an interactive prompt — defaulting to `keep` so work is never lost.
- **Synced, not copied.** A new worktree gets the committed depot state at the
  base client's changelist; uncommitted local edits in the base are not carried
  over (same as `git worktree`).
- **Collision-safe naming.** Perforce client names are global. Before creating,
  the hook checks the name: free → use it; yours at the same root → reuse;
  otherwise append `-1`, `-2`, … and never touch a client you don't own.

---

## Repository layout

```
.
├── settings.json          # hook registration (copy into your .claude/)
├── hooks/                 # copy into your .claude/hooks/
│   ├── p4-common.sh
│   ├── p4-worktree-create.sh
│   ├── p4-worktree-remove.sh
│   ├── p4-session-start.sh
│   └── p4-worktree-rm.sh
├── commands/              # copy into your .claude/commands/
│   └── rm-worktree.md
└── README.md
```

## License

See [LICENSE](LICENSE).
