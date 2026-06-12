# AgentAuth

macOS 小工具，一键开关 **Claude Code / Hermes / OpenCode** 的完全授权模式。

## 功能

- **Claude Code**: `bypassPermissions` + `PreToolUse Hook` + `~` 全目录放行
- **Hermes**: `approvals.mode: auto` + 子任务自动批准
- **OpenCode**: `permission: allow` + `yolo`

每个 Agent 独立勾选，点击「应用」即时生效。

## 构建

```bash
swiftc -o AgentAuth.app/Contents/MacOS/AgentAuth AgentAuth.swift \
  -framework SwiftUI -framework AppKit -framework Foundation \
  -parse-as-library -target arm64-apple-macosx14.0
```

## 图标

盾牌 SVG 图标，表示「完全授权保护」。
