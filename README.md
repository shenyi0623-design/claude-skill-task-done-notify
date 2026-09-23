# claude-skill-task-done-notify

A Claude Code plugin marketplace with one skill: **get a Windows toast when an
agent task finishes, but only if you're not looking at the terminal.**

A two-second answer never interrupts you. A four-minute refactor you walked
away from does.

> **Windows only.** The skill uses Win32 foreground-window detection and WinRT
> toast notifications. It does nothing on macOS or Linux.

## Install

```bash
claude plugin marketplace add shenyi0623-design/claude-skill-task-done-notify
claude plugin install task-done-notify@claude-skill-task-done-notify
```

Restart Claude Code afterwards — plugin hooks are read at session start.

Verify:

```bash
claude plugin list
powershell.exe -NoProfile -File "$env:USERPROFILE\.claude\plugins\cache\claude-skill-task-done-notify\task-done-notify\*\skills\task-done-notify\notify.ps1" -TestToast
```

## Plugins

| Plugin | What it does | Platform |
|--------|--------------|----------|
| [`task-done-notify`](plugins/task-done-notify) | Windows toast when an agent task (Claude Code, Codex, Gemini CLI, …) finishes while the terminal window is not in the foreground. Stays quiet for short answers. | Windows |

## Configure

Write `~/.claude/task-done-notify.json` with only the keys you want to change —
the plugin's own `config.json` lives in a versioned cache directory and is
replaced on every update, so don't edit it in place.

```json
{ "thresholdSeconds": 120, "sound": false }
```

Full key list, design notes and the Windows gotchas are in
[`plugins/task-done-notify/skills/task-done-notify/SKILL.md`](plugins/task-done-notify/skills/task-done-notify/SKILL.md).

## Layout

```
claude-skill-task-done-notify/
  .claude-plugin/marketplace.json     # marketplace manifest
  plugins/task-done-notify/
    .claude-plugin/plugin.json        # the ONLY file in .claude-plugin/
    hooks/hooks.json
    skills/task-done-notify/          # SKILL.md + the PowerShell scripts
```

`.claude-plugin/` holds only the manifests; every component directory
(`hooks/`, `skills/`, `commands/`, `agents/`) sits at the plugin root.

## Adding another plugin

1. `plugins/<name>/.claude-plugin/plugin.json`
2. add an entry to `.claude-plugin/marketplace.json` with
   `"source": "./plugins/<name>"`
3. `claude plugin validate .`

## Development

A `directory` marketplace points at the live tree — there is no copy step.
Claude Code re-reads `hooks/hooks.json` from the source on every session
start, so **edits take effect in the next session with no reinstall**.

```bash
claude plugin validate .                                  # marketplace + entries
claude plugin validate ./plugins/task-done-notify --strict
claude --plugin-dir ./plugins/task-done-notify -p "hi" --debug-file ./debug.log
```

A malformed `hooks/hooks.json` prevents the whole plugin from loading, and is
only reported when the plugin actually runs — so validate after every edit.

Two things to know when testing headlessly:

- `claude -p` exits as soon as the turn ends, which kills backgrounded
  `async: true` hooks mid-flight. Interactive sessions are unaffected.
- `UserPromptSubmit` fires less predictably under `-p` than interactively.
  Don't treat a missing side effect in `-p` as proof a hook is broken.

## License

MIT
