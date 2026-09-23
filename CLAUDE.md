# 项目约定

## 提交信息用中文

一律用中文写提交信息，格式参照 Conventional Commits（`feat:` / `fix:` / `docs:` / `chore:` …）。

## 插件脚本必须保持纯 ASCII

`plugins/task-done-notify/skills/task-done-notify/*.ps1` **不能出现任何非 ASCII 字符**，
中文文案一律放 `config.json`。

原因：Windows PowerShell 5.1 读取**无 BOM 的 UTF-8** 文件时按系统 ANSI 代码页解码
（中文系统 = GBK）。UTF-8 的中文字节会被解成乱码，其中某些字节恰好是引号或反斜杠，
**直接吞掉源码里的引号导致语法错误**。报错形式通常是
`LoadXml 时发生异常: HRESULT: 0xC00CE56D`——看起来像 XML 问题，实际是脚本源码已被解码破坏。

改完自检：

```bash
D=plugins/task-done-notify/skills/task-done-notify
for f in "$D"/*.ps1; do echo "$f: $(tr -d '\000-\177' < "$f" | wc -c)"; done   # 必须全为 0
```

配置一律用 `[IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)` 显式按 UTF-8 读，不受此影响。

## 改完必须校验

```bash
claude plugin validate .
claude plugin validate ./plugins/task-done-notify --strict
```

`hooks/hooks.json` 格式错误会导致**整个插件加载失败**，而且只有插件真正运行时才会报出来。

## 其他

设计取舍、性能数据和 Windows 上踩过的坑都记录在
[`plugins/task-done-notify/skills/task-done-notify/SKILL.md`](plugins/task-done-notify/skills/task-done-notify/SKILL.md)。
