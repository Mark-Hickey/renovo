# renovo

Tells a running Claude Code agent to reread its rule files when they change. The agent does not
restart and does not lose context. It also records which version of the rules each session has,
and whether the agent reread them, so you can see which agents are current and which are behind.

The design: at the end of a turn, start one background watcher if none runs. When the watcher
finds a change, it returns and alerts Claude. Because it runs in the background, it also reaches
idle agents.

## How it works

1. **SessionStart** runs `renovo baseline`. This records a sha256 of each rule file that the
   session loaded, and keeps a copy of each file.
2. **Stop** (the end of each turn) runs `renovo watch` as an `asyncRewake` hook. The watcher
   compares the fingerprints every 30 seconds. A lock keeps one watcher per session; if one is
   already running, a new one exits at once.
3. When a file changes, the watcher prints the changed, added and removed files, and a diff of
   what changed (at most 40 lines), then exits with code 2. Claude Code then wakes the agent, even
   an idle one, with that text as a system reminder. The agent finishes its current step and
   rereads the files. The next Stop starts a new watcher.
4. **Confirmation.** After a notice, the session is `told`. At each Stop, renovo reads the
   session's transcript. When it shows a `Read` of every changed or added file since the notice,
   the session is `current` again. So `current` means "reread", not only "was told".

### Watched files

- `~/.claude/CLAUDE.md`
- `<cwd>/CLAUDE.md`, `<cwd>/AGENTS.md`
- Personas: `<cwd>/.agents/persona.md` and `<cwd>/.agents/personas/*.md`
- If `RENOVO_HANDBOOK` is set, a shared rules folder: its `AGENTS.md` and `sops/*.md`
- If `RENOVO_PERSONA_CMD` is set, the persona file that `<cmd> --resolve <cwd>` prints
- Any other globs in `RENOVO_EXTRA`, separated by colons

The globs are expanded on every check, so a new SOP counts as a change. A file that does not
exist is skipped.

### The timeout

Claude Code enforces the hook `timeout` on an `asyncRewake` hook. The watcher stops itself
quietly just before the timeout (`RENOVO_MAX_RUN`, 86100 s), and the next Stop (the end of the
agent's next turn) starts a new one. An agent that stays idle for longer than that has no watcher
until its next turn. Set `RENOVO_REARM=1` to wake the agent one time instead, with a "no changes,
re-arm only" note, so that the watcher starts again at once.

## Use

```
renovo status   # each session: current, told or BEHIND; version; watcher running or off; cwd
renovo prune    # forget sessions not seen for 7 days
./test.sh       # 14 tests against a fake home, 1 s interval
```

To install, put `bin/renovo` on your `PATH`, then merge `hooks.json` into
`~/.claude/settings.json`. Get approval before you install it on a shared machine.

## Demo (about 2 minutes)

1. Make a demo rules file: `echo 'Rule 1: say hello' > ~/renovo-demo.md`.
2. Start 2 Claude sessions with the hooks and `RENOVO_EXTRA=~/renovo-demo.md`. Leave one idle and
   give the other a short task.
3. `renovo status`: both `current`.
4. Change the demo file: `echo 'Rule 2: sign off with 👍' >> ~/renovo-demo.md`.
5. Within 30 seconds the idle agent wakes by itself and rereads the file. The busy agent finishes
   its task, then does the same.
6. `renovo status`: `told` until each agent reads the file, then `current` on the new version.

The demo uses its own file, so no real rule changes and no real agent is affected.

## Settings

| Variable | Default |
|---|---|
| `RENOVO_INTERVAL` | `30` seconds |
| `RENOVO_MAX_RUN` | `86100` seconds; keep it below the hook `timeout` |
| `RENOVO_REARM` | `0` (off) |
| `RENOVO_DIFF_LINES` | `40` lines of diff in a notice |
| `RENOVO_HANDBOOK` | none |
| `RENOVO_STATE` | `~/.cache/renovo` |
| `RENOVO_PERSONA_CMD` | none |
| `RENOVO_EXTRA` | none |

## Not done yet

- **A live session.** The tests run the script directly, not through Claude Code.
- **The timeout limit.** Whether Claude Code accepts `"timeout": 86400` or limits it to a lower
  value. If it limits the value, set `RENOVO_MAX_RUN` below that limit.
- **Claude Code only.** Other agent harnesses do not have these hooks.
- **Local files only.** renovo sees a rule change when the file on this machine changes. A change
  that is on GitHub but not pulled yet is not seen.
- **One machine.** `renovo status` shows the sessions on this machine only.
- **The restart fallback.** Changes that load only at startup (tools, MCP servers, launch
  settings) still need a restart that an operator approves. renovo does not detect or request it.
