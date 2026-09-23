English | **简体中文**

# claude-skill-task-done-notify

一个 Claude Code 插件市场，目前包含一个 skill：**任务跑完时弹一条 Windows 通知——但只在你没盯着终端的时候。**

两秒的问答不会打扰你；你走开了四分钟的重构才会响。

> **仅支持 Windows。** 依赖 Win32 前台窗口检测和 WinRT toast 通知，在 macOS / Linux 上不起作用。

## 安装

```bash
claude plugin marketplace add shenyi0623-design/claude-skill-task-done-notify
claude plugin install task-done-notify@claude-skill-task-done-notify
```

装完**重启 Claude Code**——插件的 hook 只在会话启动时加载。

验证：

```bash
claude plugin list
powershell.exe -NoProfile -File "$env:USERPROFILE\.claude\plugins\cache\claude-skill-task-done-notify\task-done-notify\*\skills\task-done-notify\notify.ps1" -TestToast
```

## 插件列表

| 插件 | 作用 | 平台 |
|------|------|------|
| [`task-done-notify`](plugins/task-done-notify) | agent 任务（Claude Code、Codex、Gemini CLI …）跑完、而终端窗口不在前台时弹一条 Windows 通知。短问答不打扰。 | Windows |

## 配置

新建 `~/.claude/task-done-notify.json`，**只写你想改的键**。插件自带的 `config.json` 位于带版本号的缓存目录，每次更新会被整体替换，所以不要直接改那里。

```json
{ "thresholdSeconds": 120, "sound": false }
```

完整配置项、设计取舍和 Windows 上踩过的坑都在
[`plugins/task-done-notify/skills/task-done-notify/SKILL.md`](plugins/task-done-notify/skills/task-done-notify/SKILL.md)（中文）。

## 目录结构

```
claude-skill-task-done-notify/
  .claude-plugin/marketplace.json     # marketplace 清单
  plugins/task-done-notify/
    .claude-plugin/plugin.json        # .claude-plugin/ 里只放清单文件
    hooks/hooks.json
    skills/task-done-notify/          # SKILL.md + PowerShell 脚本
```

组件目录（`hooks/`、`skills/`、`commands/`、`agents/`）都放在插件根目录下，
`.claude-plugin/` 里只放清单。

## 再加一个插件

1. 建 `plugins/<名字>/.claude-plugin/plugin.json`
2. 在 `.claude-plugin/marketplace.json` 里加一条 `"source": "./plugins/<名字>"`
3. `claude plugin validate .`

## 开发

`directory` 类型的 marketplace 直接指向工作目录，没有拷贝步骤。Claude Code
**每次会话启动都会重新读源目录的 `hooks/hooks.json`**，所以改完源文件、开个新会话就生效，不用重装。

```bash
claude plugin validate .                                  # marketplace + 各插件条目
claude plugin validate ./plugins/task-done-notify --strict
claude --plugin-dir ./plugins/task-done-notify -p "hi" --debug-file ./debug.log
```

`hooks/hooks.json` 格式错误会导致**整个插件加载失败**，而且只有插件真正运行时才会报出来——所以每次改完都要 validate。

无头模式测试有两个坑：

- `claude -p` 在回合结束就退出，会把后台化的 `async: true` hook 一起杀掉。交互式会话没有这个问题。
- `UserPromptSubmit` 在 `-p` 下触发不如交互式可靠。不要因为 `-p` 里没看到副作用就断定 hook 坏了。

## 许可证

MIT
