---
name: task-done-notify
description: 当用户希望在 agent 任务（Claude Code / Codex / Gemini CLI 等）执行完毕、而执行任务的终端窗口不在前台时收到弹窗提醒（Windows 系统通知 toast）时使用；也用于调整触发时长阈值、通知文案、识别哪个工具在跑、判定为"前台"的终端列表，或排查通知不弹出、误弹出、脚本不执行、中文乱码、hook 卡住等问题。仅适用于 Windows。
---

# 任务完成提醒（窗口不在前台时）

## 概述

作为插件提供一对 hook：`UserPromptSubmit` 记录本轮开始时间，`Stop` 判断「终端窗口是否在前台」+「本轮耗时是否超过阈值」，只有两者都满足才弹一条 Windows 系统通知。

短问答不打扰；跑了几分钟的任务、而你去刷网页了，才会响。通知头会显示正确的工具名（Claude Code / Codex / Gemini CLI …）。

## 何时使用

- 用户说"任务跑完提醒我"、"窗口不在前台就弹提示"、"跑长任务时我去干别的"
- 通知太吵 / 从来不弹 / 弹了但没声音 / 名字显示错 → 调用户配置
- 排查 hook 未生效、卡住、乱码

不适用：macOS / Linux（依赖 Win32 `GetForegroundWindow`、`CreateToolhelp32Snapshot`、WinRT toast）。后台任务、子代理结束不在 `Stop` 覆盖范围内。

## 文件

```
<CLAUDE_PLUGIN_ROOT>/
  hooks/hooks.json                # 两个 hook 的声明
  skills/task-done-notify/
    SKILL.md
    notify.ps1                    # Stop hook：判定 + 弹通知
    mark-start.ps1                # UserPromptSubmit hook：写开始时间戳
    register-appids.ps1           # 注册各工具的 AUMID（通知头显示正确名字）
    config.json                   # 默认配置 + 中文文案（UTF-8）
```

`notify.ps1` 按这个顺序找配置，**命中即止**：

1. 环境变量 `CLAUDE_TASK_NOTIFY_CONFIG` 指向的文件
2. `~/.claude/task-done-notify.json` ← **用户改这里**
3. `<脚本同目录>/config.json`（插件内置默认值）

插件装在带版本号的缓存目录里，每次更新会被整体替换，所以**不要改插件内的 `config.json`**——改 `~/.claude/task-done-notify.json`。只需要写想覆盖的键，其余取默认；例如只改阈值：

```json
{ "thresholdSeconds": 120 }
```

## 前台判定逻辑

按顺序命中任一即判定「在前台」，否则弹通知：

| 判定 | 依据 | 覆盖场景 |
|------|------|---------|
| `own-pid` | 前台窗口属于本进程 | 兜底 |
| `window-class` | 窗口类 ∈ `terminalWindowClasses` | **Windows Terminal / 传统 conhost** |
| `process-name` | 进程名 ∈ `terminalProcesses` | 各种终端模拟器 |
| `ancestor-name` | 进程名在祖先链上 | IDE 内置终端（VS Code、JetBrains） |

**关键坑**：Windows 11 的「默认终端应用」机制会把会话**移交给 `WindowsTerminal.exe`**，此时 `cmd.exe` 的父进程仍是 `explorer.exe`——**终端进程不在祖先链上**，靠进程树判断必然失败。只能靠窗口类名 `CASCADIA_HOSTING_WINDOW_CLASS` 识别。另外 ConPTY 里 `GetConsoleWindow()` 返回的是隐藏的 `PseudoConsoleWindow`，不能用。

## 工具识别（通知头显示谁跑完的）

按这个顺序判定是哪个 agent：

1. **祖先进程名** —— 从自己往上走 12 层，匹配 `toolProcessNames`。`claude.exe` → `claude-code`
2. **环境变量标记** —— `toolEnvMarkers`，如 `CLAUDECODE=1`
3. **祖先命令行** —— 匹配 `toolCommandLinePatterns`（**最后手段，要查 WMI**）
4. 都没命中 → `defaultTool`（`generic`）

**为什么祖先优先于环境变量**：祖先链直接说明是哪个 agent 进程拉起了本脚本；而环境变量会继承泄漏——在 Claude Code 会话里跑 codex，`CLAUDECODE` 依然存在，会误判成 Claude。

**为什么必须有命令行匹配**：`codex` 和 `gemini` 都是 npm 包，实际以 `node.exe` 运行（`node .../@openai/codex/bin/codex.js`），进程名只能是 `node`，靠名字分不出来。只有 `claude` 是原生 `claude.exe`。

新增一个工具：在用户配置里加 `tools` 条目 `{显示名, appId}`，再在 `toolProcessNames` 或 `toolCommandLinePatterns` 里加匹配规则。`notify.ps1` 会在首次弹通知时自动注册对应 AUMID（`autoRegisterAppId`，默认开），无需手动操作。

## 性能（这里是本技能最容易写坏的地方）

`Stop` 在**每个回合**结束都跑一次，写法不对会拖垮体感：

| 做法 | 耗时 |
|------|------|
| PowerShell 进程启动（**不可压缩的固定成本**） | ~1500 ms |
| 编译一次 P/Invoke（`Add-Type`） | ~630 ms |
| `CreateToolhelp32Snapshot` 一次拿全部 400+ 进程 | ~160 ms |
| 基于快照在内存里走祖先链 | ~80 ms |
| 单次无过滤 `Get-CimInstance Win32_Process` | ~640 ms |
| 单次**带过滤** `Get-CimInstance -Filter "ProcessId=X"` | ~440 ms |

**绝对不要对每一层祖先各发一次 WMI 查询**——7 层就是 3 秒起，而且 WMI 会偶发卡到分钟级，直接把 hook 卡死（实测踩过一次 >120 秒）。要命令行就发**一次**不带过滤的查询，在内存里按 PID 取。

两个已经做掉的取舍：
- **先判耗时再看窗口**：短回合直接退出，完全不碰 P/Invoke。
- 祖先链用 toolhelp 快照，只有名字和环境变量都认不出来时才动用 WMI。

另外 `hooks.json` 里 `Stop` 必须 `"async": true`：PowerShell 启动固定 1.5 秒，同步执行会让每个回合都多等 1.5~2.8 秒。`UserPromptSubmit` 保持同步——异步会和 `Stop` 抢时序，导致读到上一轮的旧标记算出超大耗时而误报。

## hook 为什么要用 exec 形式

`hooks.json` 里用的是 `command` + `args` 数组，不是拼成一条 shell 字符串：

```json
{ "type": "command", "command": "powershell.exe",
  "args": ["-NoProfile", "-File", "${CLAUDE_PLUGIN_ROOT}/skills/task-done-notify/notify.ps1"] }
```

因为 hook 命令在 Git Bash 里执行（装了 Git Bash 时），而 `CLAUDE_PLUGIN_ROOT` 在 Windows 上实测解析成**带反斜杠的路径**（`C:\Users\...`）。拼进 shell 字符串里，反斜杠有被 bash 吃掉、路径被破坏的风险（claude-code issue #22449 报的就是 `C:Users…` 这种结果）。exec 形式不过 shell，逐个参数直接传给进程，没有转义和路径转换问题。实测在本机 2.1.267 上工作正常，`$CLAUDE_PLUGIN_ROOT` 环境变量同时也会被导出。

## 配置项快速参考

| 键 | 默认 | 说明 |
|----|------|------|
| `enabled` | `true` | 总开关，不用时设 `false` 即可静默 |
| `thresholdSeconds` | `30` | 短于这个秒数不提示 |
| `title` / `body` | `✅ 任务已完成` / `用时 {elapsed} · 终端窗口不在前台` | 通知两行文案，支持 `{tool}` 占位符 |
| `elapsedMinutesSeconds` | `{m} 分 {s} 秒` | 超过 1 分钟的时长格式 |
| `elapsedSeconds` | `{s} 秒` | 不足 1 分钟的格式 |
| `sound` | `true` | toast 自带提示音 |
| `fallbackSound` | `true` | toast 失败时改放系统提示音 |
| `autoRegisterAppId` | `true` | 首次弹通知时自动注册 AUMID（只写 HKCU） |
| `terminalWindowClasses` | 含 `ConsoleWindowClass`、`CASCADIA_HOSTING_WINDOW_CLASS` | 判定为终端的窗口类 |
| `tools` | Claude Code / Codex / Gemini CLI / opencode / aider / generic | 工具 id → 显示名 + appId |
| `defaultTool` | `generic` | 认不出来时的兜底 |
| `toolProcessNames` | `claude`、`codex`、`gemini`… | 进程名 → 工具 id |
| `toolCommandLinePatterns` | `@anthropic-ai/claude-code`、`@openai/codex`… | 命令行正则 → 工具 id |
| `toolEnvMarkers` | `CLAUDECODE`、`CLAUDE_CODE_ENTRYPOINT` | 环境变量兜底 |
| `terminalProcesses` | `WindowsTerminal`、`cmd`、`pwsh`、`wezterm-gui`… | 判定为终端的进程名 |
| `checkAncestorNames` | `true` | 祖先链兜底，覆盖 IDE 内置终端 |
| `debug` | `false` | 打开后写日志到 `%TEMP%\claude-task-notify\notify.log` |

想让 PyCharm 也算「在前台」，把 `pycharm64` 加进 `terminalProcesses`；默认不含 IDE 进程名，也就是在 IDE 里也算「离开」。

## 铁律：`*.ps1` 必须是纯 ASCII

**任何 `.ps1` 里都不能出现非 ASCII 字符**，中文文案一律放配置文件。

原因：Windows PowerShell 5.1 读取**无 BOM 的 UTF-8** 文件时按系统 ANSI 代码页解码（中文系统 = GBK）。UTF-8 的中文字节会被解成乱码，其中某些字节恰好是引号/反斜杠，**直接吞掉源码里的引号导致语法错误**。实测报错形式是 `LoadXml 时发生异常: HRESULT: 0xC00CE56D`（XML_E_INVALIDENCODING），看起来像 XML 问题，实际是脚本源码已被解码破坏。

改完脚本自检：

```bash
tr -d '\000-\177' < notify.ps1 | wc -c   # 必须输出 0
```

配置一律用 `[IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)` 显式按 UTF-8 读，不受此影响。

## 排查

```bash
D=~/.claude/plugins/cache/claude-skill-task-done-notify/task-done-notify/*/skills/task-done-notify

# 1. 强制弹一条通知（跳过所有判断，验证 AUMID 和文案）
powershell.exe -NoProfile -File <上面的路径>/notify.ps1 -TestToast

# 2. 看判定结果，不弹窗。session_id 决定读哪个标记文件
echo '{"session_id":"probe1"}' | powershell.exe -NoProfile -File <路径>/notify.ps1 -DryRun

# 3. 伪造前景进程名，验证两条分支
... -DryRun -SimulateForeground msedge            # -> notify
... -DryRun -SimulateForeground WindowsTerminal   # -> silent

# 4. 伪造工具，验证识别与兜底
... -DryRun -SimulateForeground msedge -SimulateTool codex   # -> Codex
                                                             # 未知 id 应回落到 AI Agent

# 5. 看日志（配置里 debug 设 true 后）
cat "$TEMP/claude-task-notify/notify.log"
```

## 常见错误

| 现象 | 原因 / 处理 |
|------|------------|
| 从不弹 | `enabled=false`；`thresholdSeconds` 太大；hook 被 `timeout` 掐掉；插件没重启加载 |
| 从不弹，且**逐个**排查都正常 | 回合结束后立刻退出会话（含 `claude -p`），异步 `Stop` hook 会被一并终止——实测日志里能看到 `backgrounding process ...` 之后进程就没了。交互式会话正常使用不受影响 |
| 插件改了没生效（`directory` 源） | 不会自动重装，但**下一次会话会直接读源目录的 hooks.json**，改完开新会话即可 |
| 一直弹（人在终端里也弹） | 终端类名/进程名不在列表里 → 开 `debug` 看日志的 `fg name/class`，加进 `terminalProcesses` / `terminalWindowClasses` |
| 每回合都卡几秒 | `Stop` 没设 `async: true` |
| 偶发完全不弹且无日志 | hook 内部卡在 WMI。检查有没有对每层祖先单独发 `Get-CimInstance` |
| hook 静默不执行 | 插件 hook 拼成 shell 字符串时，`CLAUDE_PLUGIN_ROOT` 的反斜杠被 bash 吃掉 → 用 exec 形式（`command` + `args`） |
| 脚本报 `0xC00CE56D` 或中文乱码 | 往 `.ps1` 里写了中文 → 按上面「铁律」清成 ASCII |
| 通知头显示成别的工具名 | 识别错了，用 `-DryRun` 看 `tool` 字段；或 `autoRegisterAppId` 被关了但 AUMID 又没注册过 |
| 有提示没声音 | 系统「专注助手 / 勿扰模式」会吞掉 toast，去「设置 → 系统 → 通知」关掉 |

## 卸载与回滚

```bash
claude plugin uninstall task-done-notify@claude-skill-task-done-notify
# 用户配置和残留状态
rm ~/.claude/task-done-notify.json
rm -rf "$TEMP/claude-task-notify"
# 自动注册的 AUMID
powershell -NoProfile -Command "Remove-Item 'HKCU:\Software\Classes\AppUserModelId\AgentTaskDone.*' -Recurse -Force"
```
