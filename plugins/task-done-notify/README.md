# task-done-notify

Pops a Windows toast when an agent task finishes — but **only** when the
terminal window running the agent is not in the foreground, and only when the
turn ran longer than a threshold (default 30 s).

A two-second answer never interrupts you. A four-minute refactor you walked
away from does.

## Requirements

Windows. PowerShell 5.1 (ships with Windows). No admin rights, no npm
packages, no dependencies.

## How it works

Two hooks, declared in `hooks/hooks.json`:

| Event | Script | Job |
|-------|--------|-----|
| `UserPromptSubmit` | `mark-start.ps1` | stamps the moment you hit Enter |
| `Stop` | `notify.ps1` | decides whether to notify, and shows the toast |

`notify.ps1` notifies only if **all** hold: the turn lasted at least
`thresholdSeconds`, and the foreground window is not the terminal running the
agent. Detection is by Win32 window class (Windows Terminal is recognised via
`CASCADIA_HOSTING_WINDOW_CLASS`) — the terminal process is *not* an ancestor
on Windows 11, because the default-terminal handoff puts `WindowsTerminal.exe`
outside the process tree.

The toast header shows which agent finished (Claude Code, Codex, Gemini CLI,
opencode, Aider, …), detected from the ancestor process chain.

## Configuration

Edit `~/.claude/task-done-notify.json` — **not** the `config.json` inside the
plugin, which lives in a versioned cache directory that is replaced on every
update. Only the keys you set override the defaults:

```json
{
  "thresholdSeconds": 120,
  "sound": false
}
```

Full key list: [`skills/task-done-notify/SKILL.md`](skills/task-done-notify/SKILL.md).

| Key | Default | Use |
|-----|---------|-----|
| `enabled` | `true` | master switch — set `false` to go quiet |
| `thresholdSeconds` | `30` | don't notify for turns shorter than this |
| `title` / `body` | `✅ 任务已完成` / `用时 {elapsed} · 终端窗口不在前台` | toast text; `{tool}` and `{elapsed}` are substituted |
| `sound` / `fallbackSound` | `true` | toast sound; system sound if the toast fails |
| `autoRegisterAppId` | `true` | register the toast's AppUserModelId on first use |
| `terminalProcesses` | terminals only | add `pycharm64` etc. to count an IDE as "at the terminal" |
| `debug` | `false` | log decisions to `%TEMP%\claude-task-notify\notify.log` |

## What it writes outside the plugin

- `%TEMP%\claude-task-notify\<session>.start` — one timestamp per session, pruned after a day
- `%TEMP%\claude-task-notify\notify.log` — only when `debug` is on
- `HKCU:\Software\Classes\AppUserModelId\AgentTaskDone.*` — so the toast header reads
  "Claude Code" instead of "Windows PowerShell". User-scoped; disable with
  `"autoRegisterAppId": false`.

No network access. Nothing runs unless a hook fires.

## Troubleshooting

```bash
P=~/.claude/plugins/cache/claude-skill-task-done-notify/task-done-notify/*/skills/task-done-notify

powershell.exe -NoProfile -File $P/notify.ps1 -TestToast        # force a toast now
echo '{"session_id":"probe"}' | powershell.exe -NoProfile -File $P/notify.ps1 -DryRun
```

`-DryRun` prints the decision as JSON without notifying — including the
detected `tool` and the foreground window, which is what you want when the
toast fires at the wrong time (or never).
