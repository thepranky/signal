import Foundation

/// Installs, detects, and removes Signal's Claude Code hooks by editing the
/// user's global ~/.claude/settings.json. This mirrors install/install.py so a
/// downloaded app can set itself up with one click, no terminal or repo clone.
enum HookInstaller {

    enum InstallError: LocalizedError {
        case hookScriptMissing
        case settingsUnreadable
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .hookScriptMissing:
                return "The bundled hook script is missing from Signal.app."
            case .settingsUnreadable:
                return "Could not read ~/.claude/settings.json (is it valid JSON?)."
            case .writeFailed(let why):
                return "Could not update settings: \(why)"
            }
        }
    }

    /// event name, matcher (nil = none), status argument passed to the hook.
    private static let managed: [(event: String, matcher: String?, status: String)] = [
        ("UserPromptSubmit", nil, "running"),
        ("PreToolUse", "*", "running"),
        ("PostToolUse", "*", "running"),
        ("Notification", "permission_prompt", "waiting"),
        ("PermissionRequest", nil, "waiting"),
        ("Stop", nil, "done"),
        ("SessionEnd", nil, "end"),
    ]

    private static let marker = "signal_hook.py"

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Absolute path to the hook script bundled inside Signal.app.
    static var bundledHookScript: URL? {
        Bundle.main.url(forResource: "signal_hook", withExtension: "py")
    }

    private static func command(for status: String, hookPath: String) -> String {
        // /usr/bin/env avoids depending on the script's +x bit; quotes guard
        // against spaces in the app's install path.
        "/usr/bin/env python3 \"\(hookPath)\" \(status)"
    }

    // MARK: - Detection

    /// True if any Signal-managed hook is present in the settings file.
    static func isInstalled() -> Bool {
        guard let settings = loadSettings(),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for groups in hooks.values {
            guard let groups = groups as? [[String: Any]] else { continue }
            if groups.contains(where: isSignalGroup) { return true }
        }
        return false
    }

    // MARK: - Install / uninstall

    static func install() throws {
        guard let hookURL = bundledHookScript else { throw InstallError.hookScriptMissing }

        var settings = loadSettings() ?? [:]
        stripSignalHooks(&settings)

        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        for entry in managed {
            var group: [String: Any] = [
                "hooks": [["type": "command",
                           "command": command(for: entry.status, hookPath: hookURL.path)]]
            ]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            var groups = (hooks[entry.event] as? [[String: Any]]) ?? []
            groups.append(group)
            hooks[entry.event] = groups
        }
        settings["hooks"] = hooks

        try ensureStateDirectory()
        try writeSettings(settings)
    }

    static func uninstall() throws {
        var settings = loadSettings() ?? [:]
        stripSignalHooks(&settings)
        try writeSettings(settings)
    }

    // MARK: - Helpers

    private static func isSignalGroup(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(marker) ?? false }
    }

    private static func stripSignalHooks(_ settings: inout [String: Any]) {
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !isSignalGroup($0) }
            if kept.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = kept }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        else { settings["hooks"] = hooks }
    }

    private static func loadSettings() -> [String: Any]? {
        let url = settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    private static func ensureStateDirectory() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".signal/sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let url = settingsURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let backup = url.deletingPathExtension()
                    .appendingPathExtension("json.signal-bak.\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.copyItem(at: url, to: backup)
            }
            let data = try JSONSerialization.data(
                withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }
}
