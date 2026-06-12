import AppKit
import SwiftUI

// MARK: - JSON read/write helpers
func readJSON(_ path: String) -> [String: Any]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json
}

func writeJSON(_ path: String, _ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

// MARK: - App State
class AppState: ObservableObject {
    @Published var ccEnabled: Bool = false
    @Published var hermesEnabled: Bool = false
    @Published var opencodeEnabled: Bool = false
    @Published var statusMessage: String = ""

    let home = FileManager.default.homeDirectoryForCurrentUser
    lazy var ccPath = home.appendingPathComponent(".claude/settings.json").path
    lazy var opencodePath = home.appendingPathComponent(".config/opencode/opencode.json").path
    lazy var hermesPath = home.appendingPathComponent(".hermes/config.yaml").path
    lazy var hookDir = home.appendingPathComponent(".claude/hooks").path
    lazy var hookScript = home.appendingPathComponent(".claude/hooks/auto-approve.sh").path

    // Projects with .claude/ dir on Desktop
    func projectDirs() -> [String] {
        let fm = FileManager.default
        let desktop = home.appendingPathComponent("Desktop")
        var dirs: [String] = []
        if let entries = try? fm.contentsOfDirectory(atPath: desktop.path) {
            for entry in entries where entry.hasPrefix(".") == false {
                let proj = desktop.appendingPathComponent(entry)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: proj.path, isDirectory: &isDir), isDir.boolValue,
                   fm.fileExists(atPath: proj.appendingPathComponent(".claude").path, isDirectory: &isDir), isDir.boolValue {
                    dirs.append(proj.path)
                }
            }
        }
        return dirs
    }

    func projectCCPaths() -> [String] {
        projectDirs().map { $0 + "/.claude/settings.json" }
    }

    func projectLocalCCPaths() -> [String] {
        projectDirs().map { $0 + "/.claude/settings.local.json" }
    }

    init() {
        loadCurrentState()
    }
    
    /// Called from onAppear to ensure @Published values refresh the UI
    func refreshUI() {
        loadCurrentState()
    }

    func loadCurrentState() {
        if let cc = readJSON(ccPath) {
            let perm = cc["permissions"] as? [String: Any]
            let hasHook = cc["hooks"] != nil
            // Check project-level settings.json for hooks
            let projectHooks = !hasHook && projectCCPaths().lazy.compactMap({ readJSON($0)?["hooks"] }).first != nil
            // Project-level settings.local.json may override global bypassPermissions; ensure it's set
            let localFiles = projectLocalCCPaths()
            let localBypass = localFiles.isEmpty || localFiles.lazy.compactMap({ (readJSON($0)?["permissions"] as? [String: Any])?["defaultMode"] as? String }).first == "bypassPermissions"
            ccEnabled = perm?["defaultMode"] as? String == "bypassPermissions" && (hasHook || projectHooks) && localBypass
        }
        if let oc = readJSON(opencodePath) {
            let yolo = oc["yolo"]
            opencodeEnabled = (yolo as? Bool) == true
        }
        if let content = try? String(contentsOfFile: hermesPath) {
            hermesEnabled = content.contains("mode: auto") && content.contains("subagent_auto_approve: true")
        }
    }

    func apply() {
        try? FileManager.default.createDirectory(atPath: hookDir, withIntermediateDirectories: true)
        let hookContent = "#!/bin/bash\n" + #"echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'"#
        try? hookContent.write(toFile: hookScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: hookScript)

        // ── Claude Code ──
        let hookConfig: [[String: Any]] = [[
            "matcher": "Read|Write|Edit|Bash|Glob|Grep|LS",
            "hooks": [["type": "command", "command": "bash \(hookScript)"]]
        ]]
        // Write to user-level (CC loads hooks at session start, daemon strips later)
        if var cc = readJSON(ccPath) {
            if ccEnabled {
                cc["permissions"] = ["defaultMode": "bypassPermissions", "allow": ["*"]]
                cc["skipDangerousModePermissionPrompt"] = true
                cc["additionalDirectories"] = [home.path]
                cc["hooks"] = ["PreToolUse": hookConfig]
            } else {
                cc["permissions"] = ["defaultMode": "default", "allow": []]
                cc.removeValue(forKey: "skipDangerousModePermissionPrompt")
                cc.removeValue(forKey: "additionalDirectories")
                cc.removeValue(forKey: "hooks")
                try? FileManager.default.removeItem(atPath: hookScript)
            }
            writeJSON(ccPath, cc)
        }
        // Project-level .claude/ (hooks + local permissions)
        for projPath in projectCCPaths() {
            if ccEnabled {
                writeJSON(projPath, ["hooks": ["PreToolUse": hookConfig]])
            } else {
                try? FileManager.default.removeItem(atPath: projPath)
            }
        }
        // Project-level .claude/settings.local.json may override global bypassPermissions
        for localPath in projectLocalCCPaths() {
            if ccEnabled {
                var local = readJSON(localPath) ?? [:]
                var perm = local["permissions"] as? [String: Any] ?? [:]
                perm["defaultMode"] = "bypassPermissions"
                local["permissions"] = perm
                writeJSON(localPath, local)
            } else {
                if var local = readJSON(localPath) {
                    if var perm = local["permissions"] as? [String: Any] {
                        perm.removeValue(forKey: "defaultMode")
                        if perm.isEmpty {
                            local.removeValue(forKey: "permissions")
                        } else {
                            local["permissions"] = perm
                        }
                        writeJSON(localPath, local)
                    }
                }
            }
        }

        // ── OpenCode ──
        if var oc = readJSON(opencodePath) {
            if opencodeEnabled {
                oc["permission"] = "allow"; oc["yolo"] = true
            } else {
                oc.removeValue(forKey: "permission"); oc.removeValue(forKey: "yolo")
            }
            writeJSON(opencodePath, oc)
        }

        // ── Hermes ──
        if let content = try? String(contentsOfFile: hermesPath) {
            let lines = content.components(separatedBy: "\n")
            var out: [String] = []; var i = 0
            let p1 = try? NSRegularExpression(pattern: "^approvals:\\s*$")
            let p2 = try? NSRegularExpression(pattern: "^  subagent_auto_approve:\\s*(true|false)")
            let p3 = try? NSRegularExpression(pattern: "^hooks_auto_accept:\\s*(true|false)")
            while i < lines.count {
                let line = lines[i]
                if hermesEnabled {
                    if let p = p1, p.firstMatch(in: line, range: NSRange(location: 0, length: line.count)) != nil,
                       i+1 < lines.count, lines[i+1].contains("mode: manual") {
                        out.append(line); out.append(lines[i+1].replacingOccurrences(of: "manual", with: "auto")); i+=2; continue
                    }
                    if let p = p2, let m = p.firstMatch(in: line, range: NSRange(location: 0, length: line.count)), m.numberOfRanges > 1,
                       (line as NSString).substring(with: m.range(at: 1)) == "false" {
                        out.append(line.replacingOccurrences(of: "false", with: "true")); i+=1; continue
                    }
                    if let p = p3, let m = p.firstMatch(in: line, range: NSRange(location: 0, length: line.count)), m.numberOfRanges > 1,
                       (line as NSString).substring(with: m.range(at: 1)) == "false" {
                        out.append(line.replacingOccurrences(of: "false", with: "true")); i+=1; continue
                    }
                } else {
                    if let p = p1, p.firstMatch(in: line, range: NSRange(location: 0, length: line.count)) != nil,
                       i+1 < lines.count, lines[i+1].contains("mode: auto") {
                        out.append(line); out.append(lines[i+1].replacingOccurrences(of: "auto", with: "manual")); i+=2; continue
                    }
                    if let p = p2, let m = p.firstMatch(in: line, range: NSRange(location: 0, length: line.count)), m.numberOfRanges > 1,
                       (line as NSString).substring(with: m.range(at: 1)) == "true" {
                        out.append(line.replacingOccurrences(of: "true", with: "false")); i+=1; continue
                    }
                    if let p = p3, let m = p.firstMatch(in: line, range: NSRange(location: 0, length: line.count)), m.numberOfRanges > 1,
                       (line as NSString).substring(with: m.range(at: 1)) == "true" {
                        out.append(line.replacingOccurrences(of: "true", with: "false")); i+=1; continue
                    }
                }
                out.append(line); i+=1
            }
            try? out.joined(separator: "\n").write(toFile: hermesPath, atomically: true, encoding: .utf8)
        }

        statusMessage = "✅ 已应用"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.statusMessage = "" }
    }
}

struct ContentView: View {
    @StateObject private var state = AppState()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "shield.checkered").font(.title2).foregroundColor(.accentColor)
                Text("Agent 完全授权").font(.headline)
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
            Divider()
            HStack(spacing: 4) {
                Text("PreToolUse Hook 无死角放行所有文件访问").font(.caption).foregroundColor(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 4)
            VStack(spacing: 4) {
                AgentRow(icon: "terminal", name: "Claude Code", desc: "bypassPermissions + hook + ~全目录", isOn: $state.ccEnabled)
                AgentRow(icon: "leaf", name: "Hermes", desc: "approvals.mode: auto", isOn: $state.hermesEnabled)
                AgentRow(icon: "chevron.left.forwardslash.chevron.right", name: "OpenCode", desc: "permission: allow + yolo", isOn: $state.opencodeEnabled)
            }.padding(.vertical, 12)
            Divider()
            HStack {
                if !state.statusMessage.isEmpty { Text(state.statusMessage).font(.subheadline).foregroundColor(.green) }
                Spacer()
                Button("应用") { state.apply() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 380, height: 280)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { state.refreshUI() }
    }
}

struct AgentRow: View {
    let icon: String; let name: String; let desc: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.body).foregroundColor(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body)
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small)
        }.padding(.horizontal, 20).padding(.vertical, 6)
    }
}

@main
struct AgentAuthApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView().onAppear {
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
