# AgentAuth

> **仅支持 macOS** — 使用 SwiftUI + AppKit 构建，依赖 macOS 原生框架。

一键开关 **Claude Code / Hermes / OpenCode** 的完全授权模式。

## 功能

- **Claude Code**: `bypassPermissions` + `PreToolUse Hook` + `~` 全目录放行
- **Hermes**: `approvals.mode: auto` + 子任务自动批准
- **OpenCode**: `permission: allow` + `yolo`

每个 Agent 独立勾选，点击「应用」即时生效。

## 使用

1. 从 [Releases](https://github.com/luisliang/agent-auth/releases) 下载 `AgentAuth.app.zip`
2. 解压，双击运行
3. 勾选要授权的 Agent，点击「应用」

## 自己构建

```bash
swiftc -o AgentAuth.app/Contents/MacOS/AgentAuth AgentAuth.swift \
  -framework SwiftUI -framework AppKit -framework Foundation \
  -parse-as-library -target arm64-apple-macosx14.0
```

## 技术原理

| 层级 | 机制 | 作用 |
|------|------|------|
| 权限模式 | `bypassPermissions` | 跳过所有工具级权限弹窗 |
| Hook | `PreToolUse` | 在工具执行前无条件放行，拦截外部目录读取检查 |
| 目录 | `additionalDirectories: ~` | 预授权 home 目录下所有文件访问 |

## 图标

盾牌 SVG 图标，表示「完全授权保护」。
