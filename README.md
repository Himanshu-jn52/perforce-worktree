# Perforce worktree isolation for Claude Code

Give every Claude Code worktree its own Perforce client (workspace) so file
edits, syncs, and pending changes in one session never touch another — the same
isolation `git worktree` gives Git users, implemented for p4 (which has no
native worktree concept).

## How it maps to Claude Code's worktree hooks

Claude Code fires `WorktreeCreate` / `WorktreeRemove` when it spins worktrees up
and down (`claude --worktree <name>`). For non-git version control you supply
the create/remove logic yourself — these scripts are that logic.

| Script | Hook / role | Does |
| --- | --- | --- |
| `p4-worktree-create.sh` | `WorktreeCreate` | Picks a collision-safe client `<base>-claude-<name>`, roots it at the worktree dir, syncs it to the base client's changelist, writes `.p4config`, prints the path. |
| `p4-session-start.sh` | `SessionStart` | Reads that `.p4config` and exports `P4CLIENT` into the session via `CLAUDE_ENV_FILE`, so every Bash command in the session uses the isolated client. |
| `p4-worktree-remove.sh` | `WorktreeRemove` | Inspects the client for open/shelved work and cleans up per policy. |
| `p4-worktree-rm.sh` | manual helper | Lists worktrees, or removes one by name/client. Backs the `/rm-worktree` command. |
| `p4-common.sh` | shared | Logging, p4-var resolution (`p4 set` fallback), JSON stdin parsing, sanitizing. |

### Design facts that shaped this (and differ from a naive spec)

1. **`WorktreeCreate` can't set the session's `P4CLIENT` directly.** That hook
   has no `CLAUDE_ENV_FILE`, and a hook subprocess can't mutate the parent's
   env. So create writes a `.p4config`, and the **`SessionStart`** hook is what
   actually binds `P4CLIENT` for the session. Hence three hooks, not two.
2. **`WorktreeRemove` can't prompt or block.** Claude Code's docs are explicit:
   no decision control, can't block removal, can't prompt, runs async. So
   "ask the user to shelve/revert/keep" is impossible there. Instead the
   behavior is a **policy env var** (`P4_WORKTREE_ON_DIRTY`, default `keep` =
   never lose work), with loud stderr logging.
3. **The payload may not include a directory.** For non-git worktrees Claude
   sends a name but (in practice) no path, so the create hook **chooses the
   directory itself** — a sibling of the **project root** (so placement is the
   same no matter which subdir you launch from) and **outside** the base client's
   root (you must never nest one p4 client root inside another). It prints that
   path; Claude `cd`s into whatever the hook prints on stdout.
4. **Client names are global in Perforce**, not per-user. Create checks for
   collisions and never clobbers a client it doesn't own (see below).
5. **Content is synced from the depot, not copied.** The worktree gets the
   committed state at the base client's changelist — uncommitted local work in
   the base workspace is **not** carried over (same as `git worktree`).

## Layout — why this lives at the REPO ROOT

Claude discovers `settings.json` hooks and slash commands by walking **up** the
directory tree from the session's start dir (never into siblings). The canonical
config therefore lives at the **repo root**, the common ancestor of the launch
dir and any in-tree subdir:

Worktrees, however, are placed *outside* the repo (a sibling of the project root,
e.g. `…/p4python_ws_100_commits-abc`) so a p4 client root is never nested inside
the base client's root. Walk-up from there would miss the repo's `.claude`, so
**the create hook symlinks `.claude` into each worktree** (`<worktree>/.claude ->
<repo>/.claude`). That makes the hooks and `/rm-worktree` resolve inside worktree
sessions too. So the config has one real home (below) plus a symlink per worktree:

```
repo/.claude/                 # repo root: ancestor of main/ AND every worktree
├── settings.json             # hook registration
├── commands/
│   └── rm-worktree.md         # the /rm-worktree command
└── hooks/
    ├── p4-common.sh           # shared helpers (sourced by the others)
    ├── p4-worktree-create.sh
    ├── p4-worktree-remove.sh
    ├── p4-session-start.sh
    ├── p4-worktree-rm.sh
    └── README.md              # this file
```

Putting it under `repo/main/.claude` would NOT work: a session launched from
the repo root, or a worktree session beside the repo, never looks into the
sibling `main/`.

## Install

1. Keep the scripts together in `hooks/` (they source `p4-common.sh` from their
   own directory and reference each other).
2. Make them executable: `chmod +x hooks/*.sh`
3. Register the hooks in `settings.json` at the repo root. `$CLAUDE_PROJECT_DIR`
   resolves (via walk-up) to the repo root for both `main/` and worktree
   sessions:
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
   Restart Claude Code (or `/hooks`) to load them.

## Removing worktrees

There is **no built-in `claude` command** to remove a worktree, and exiting a
session does **not** remove it (that fires `SessionEnd`, not `WorktreeRemove`).
A non-git worktree also won't show Claude's keep/remove prompt (that flow is
git-state based). So remove explicitly:

**Slash command** (`.claude/commands/rm-worktree.md`; restart Claude after first
adding it so the new commands dir is watched):

```
/rm-worktree                     # list all worktrees + open/shelved counts
/rm-worktree <name>              # remove (keep policy; refuses if dirty)
/rm-worktree <name> revert       # discard open files, then remove
/rm-worktree <name> shelve       # shelve work server-side, then remove dir
```

`<name>` may be the short suffix (`update-client-test`) or the full client name.

**Direct script** (equivalent):

```bash
.claude/hooks/p4-worktree-rm.sh                 # list
.claude/hooks/p4-worktree-rm.sh <name> [policy] # remove
```

## Configuration

| Env var | Default | Meaning |
| --- | --- | --- |
| `P4_WORKTREE_ON_DIRTY` | `keep` | What removal does when the workspace has open/shelved files. |

- **`keep`** — if there's uncommitted/shelved work, do nothing destructive;
  leave the client and directory so nothing is lost (logs how to recover).
- **`shelve`** — shelve open files server-side, revert to unlock, remove the
  directory, but **keep the client** (shelves live on it; delete it after you
  `p4 unshelve`).
- **`revert`** — **discard** open files, delete shelved changelists, delete the
  client, remove the directory. Destructive; opt in deliberately.

A clean workspace (no open or shelved files) is always fully removed.

## Collision-safe client naming

Perforce client names are server-wide. Before creating, the hook checks the
desired name `<base>-claude-<name>`:

- **free** → use it
- **owned by you, rooted at this worktree path** → reuse it (resume case)
- **owned by another user** → never touched; auto-appends `-1`, `-2`, … until free
- **yours but rooted elsewhere** → also bumps, so it can't clobber another workspace

Cross-user collisions are unlikely anyway because the name is prefixed with your
base client, which is itself globally unique to its owner.

## Perforce requirements & permissions

- `p4` (Helix CLI) on `PATH`.
- A reachable server (`P4PORT`) and a **valid login** (`p4 login`) — create
  aborts with a clear message if the ticket is missing.
- `P4CLIENT`, `P4PORT`, `P4USER` resolvable via the environment **or** `p4 set`
  / `P4ENVIRO` (this machine uses the enviro file — the scripts handle both).
- Protections (`p4 protect`) granting at least `write` on the depot paths in the
  base client's `View`, plus the ability to create clients (default access).
- Disk space for a second synced workspace tree per concurrent worktree.

## Error handling built in

- **`p4` not on PATH** — create aborts clearly; remove/session-start skip p4 work.
- **No `P4CLIENT` / `P4PORT`** — create aborts before touching anything.
- **Base client missing / not logged in** — create aborts (suggests `p4 login`).
- **Name collision** — auto-suffixes; never modifies a client you don't own.
- **Sync failure** — the half-created client is deleted and create aborts, so
  Claude never `cd`s into a broken workspace.
- **Removal safety** — refuses to `rm -rf` `/`, `$HOME`, or an empty path; reads
  `Root` from the clean `p4 client -o` spec (not scraped text); never deletes a
  client that still holds work under the `keep`/`shelve` policies.
