import AppKit
import SwiftUI

// MARK: - Config Models
struct CCConfig: Codable {
    var permissions: CCPermissions?
    var skipDangerousModePermissionPrompt: Bool?
    var additionalDirectories: [String]?
    var hooks: [String: [HookRule]]?
    var env: [String: String]?
    var includeCoAuthoredBy: Bool?
    var model: String?
    var theme: String?
}

struct CCPermissions: Codable {
    var defaultMode: String?
    var allow: [String]?
}

struct HookRule: Codable {
    var matcher: String?
    var hooks: [HookCommand]?
}

struct HookCommand: Codable {
    var type: String?
    var command: String?
}

struct OpenCodeConfig: Codable {
    var permission: JSONValue?
    var yolo: Bool?
    var plugin: [String]?
    var mcp: [String: MCPConfig]?
    var skills: SkillsConfig?
    var provider: [String: JSONValue]?
}

struct MCPConfig: Codable {
    var type: String?
    var command: [String]?
    var enabled: Bool?
}

struct SkillsConfig: Codable {
    var paths: [String]?
}

enum JSONValue: Codable {
    case string(String)
    case bool(Bool)
    case dictionary([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) { self = .string(str) }
        else if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
        else if let dict = try? container.decode([String: JSONValue].self) { self = .dictionary(dict) }
        else { throw DecodingError.typeMismatch(JSONValue.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported type")) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str): try container.encode(str)
        case .bool(let bool): try container.encode(bool)
        case .dictionary(let dict): try container.encode(dict)
        }
    }
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

    init() { loadCurrentState() }

    func loadCurrentState() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: ccPath)),
           let config = try? JSONDecoder().decode(CCConfig.self, from: data) {
            ccEnabled = config.permissions?.defaultMode == "bypassPermissions" && config.hooks != nil
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: opencodePath)),
           let config = try? JSONDecoder().decode(OpenCodeConfig.self, from: data) {
            opencodeEnabled = config.yolo == true
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

        if let data = try? Data(contentsOf: URL(fileURLWithPath: ccPath)),
           var config = try? JSONDecoder().decode(CCConfig.self, from: data) {
            if ccEnabled {
                let hook = HookRule(matcher: "Read|Write|Edit|Bash|Glob|Grep|LS", hooks: [HookCommand(type: "command", command: "bash \(hookScript)")])
                config.permissions = CCPermissions(defaultMode: "bypassPermissions", allow: ["*"])
                config.skipDangerousModePermissionPrompt = true
                config.additionalDirectories = [home.path]
                config.hooks = ["PreToolUse": [hook]]
            } else {
                config.permissions = CCPermissions(defaultMode: "default", allow: [])
                config.skipDangerousModePermissionPrompt = nil
                config.additionalDirectories = nil
                config.hooks = nil
                try? FileManager.default.removeItem(atPath: hookScript)
            }
            if let encoded = try? JSONEncoder().encode(config),
               let json = try? JSONSerialization.jsonObject(with: encoded),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? pretty.write(to: URL(fileURLWithPath: ccPath))
            }
        }

        if let data = try? Data(contentsOf: URL(fileURLWithPath: opencodePath)),
           var config = try? JSONDecoder().decode(OpenCodeConfig.self, from: data) {
            if opencodeEnabled { config.permission = .string("allow"); config.yolo = true }
            else { config.permission = nil; config.yolo = nil }
            if let encoded = try? JSONEncoder().encode(config),
               let json = try? JSONSerialization.jsonObject(with: encoded),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? pretty.write(to: URL(fileURLWithPath: opencodePath))
            }
        }

        if let content = try? String(contentsOfFile: hermesPath) {
            let lines = content.components(separatedBy: "\n")
            var out: [String] = []; var i = 0
            while i < lines.count {
                let line = lines[i]
                let p1 = try? NSRegularExpression(pattern: "^approvals:\\s*$")
                let p2 = try? NSRegularExpression(pattern: "^  subagent_auto_approve:\\s*(true|false)")
                let p3 = try? NSRegularExpression(pattern: "^  hooks_auto_accept:\\s*(true|false)")
                if hermesEnabled {
                    if let p = p1, p.firstMatch(in: line, range: NSRange(location: 0, length: line.count)) != nil,
                       i+1 < lines.count, lines[i+1].contains("mode: manual") {
                        out.append(line); out.append(lines[i+1].replacingOccurrences(of: "manual", with: "auto")); i+=2; continue
                    }
                    if let p = p2, let m = p.firstMatch(in: line, range: NSRange(location: 0, length: line.count)), m.numberOfRanges > 1 {
                        if (line as NSString).substring(with: m.range(at: 1)) == "false" { out.append(line.replacingOccurrences(of: "false", with: "true")); i+=1; continue }
                    }
                    if let p = p3, let m = p.firstMatch(in: line, range: NSRange(location: 0, length: line.count)), m.numberOfRanges > 1 {
                        if (line as NSString).substring(with: m.range(at: 1)) == "false" { out.append(line.replacingOccurrences(of: "false", with: "true")); i+=1; continue }
                    }
                } else {
                    if let p = p1, p.firstMatch(in: line, range: NSRange(location: 0, length: line.count)) != nil,
                       i+1 < lines.count, lines[i+1].contains("mode: auto") {
                        out.append(line); out.append(lines[i+1].replacingOccurrences(of: "auto", with: "manual")); i+=2; continue
                    }
                    if let p = p2, let m = p.firstMatch(in: line, range: NSRange(location: 0, length: line.count)), m.numberOfRanges > 1 {
                        if (line as NSString).substring(with: m.range(at: 1)) == "true" { out.append(line.replacingOccurrences(of: "true", with: "false")); i+=1; continue }
                    }
                    if let p = p3, let m = p.firstMatch(in: line, range: NSRange(location: 0, length: line.count)), m.numberOfRanges > 1 {
                        if (line as NSString).substring(with: m.range(at: 1)) == "true" { out.append(line.replacingOccurrences(of: "true", with: "false")); i+=1; continue }
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
