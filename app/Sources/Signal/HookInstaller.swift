import Foundation

/// Installs, detects, and removes Signal's hooks by editing the user's global
/// Claude, Cursor, and Codex hook files. This mirrors install/install.py so a
/// downloaded app can set itself up with one click, no terminal or repo clone.
enum HookInstaller {

    enum InstallError: LocalizedError {
        case hookScriptMissing
        case noSupportedProviders
        case settingsUnreadable
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .hookScriptMissing:
                return "The bundled hook script is missing from Signal.app."
            case .noSupportedProviders:
                return "No Claude, Cursor, or Codex config directories were found. Open at least one supported agent, then try again."
            case .settingsUnreadable:
                return "A hooks settings file (~/.claude/settings.json or "
                     + "~/.cursor/hooks.json or ~/.codex/hooks.json) exists but "
                     + "isn't valid JSON. Fix or remove it, then try again — "
                     + "Signal won't overwrite it."
            case .writeFailed(let why):
                return "Could not update settings: \(why)"
            }
        }
    }

    /// Claude Code hooks: event name, matcher (nil = none), status argument.
    private static let managed: [(event: String, matcher: String?, status: String)] = [
        ("UserPromptSubmit", nil, "running"),
        ("PreToolUse", "*", "running"),
        ("PostToolUse", "*", "running"),
        ("PostToolUseFailure", "*", "running"),
        ("Notification", "permission_prompt", "waiting"),
        ("PermissionRequest", nil, "waiting"),
        ("Stop", nil, "done"),
        ("StopFailure", nil, "done"),
        ("SessionEnd", nil, "end"),
    ]

    /// Cursor's native hooks: event name + status argument. Cursor has no event
    /// equivalent to Claude's permission prompt, so Cursor sessions never enter
    /// the "waiting" (yellow) state — only running → done. Matchers are omitted
    /// so the tool-use hooks fire for every tool.
    private static let managedCursor: [(event: String, status: String)] = [
        ("beforeSubmitPrompt", "running"),
        ("preToolUse", "running"),
        ("postToolUse", "running"),
        ("postToolUseFailure", "running"),
        ("stop", "done"),
        ("sessionEnd", "end"),
    ]

    /// Codex user hooks use the same nested shape as Claude Code. Codex does
    /// not document a session-end event for hooks today, so Codex sessions age
    /// out via Signal's normal staleness timeout.
    private static let managedCodex: [(event: String, matcher: String?, status: String)] = [
        ("UserPromptSubmit", nil, "running"),
        ("PreToolUse", "*", "running"),
        ("PostToolUse", "*", "running"),
        ("PermissionRequest", nil, "waiting"),
        ("Stop", nil, "done"),
    ]

    /// Unique token embedded in every command we install, so we identify and
    /// remove only our own hooks (never a user's unrelated hook).
    private static let marker = "SIGNAL_HOOK=1"

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Cursor's native user-level hooks file. Installing here means Cursor
    /// tracking no longer depends on Cursor's optional Claude-compatibility
    /// bridge being enabled.
    static var cursorSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/hooks.json")
    }

    /// Codex's user-level hooks file. Keep the first implementation
    /// intentionally simple: always target the documented default.
    static var codexHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/hooks.json")
    }

    private static var claudeDirectoryURL: URL { settingsURL.deletingLastPathComponent() }
    private static var cursorDirectoryURL: URL { cursorSettingsURL.deletingLastPathComponent() }
    private static var codexDirectoryURL: URL { codexHooksURL.deletingLastPathComponent() }

    private static var signalHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".signal")
    }

    /// Stable on-disk location of the hook. Installed commands point here so they
    /// keep working even if Signal.app is moved or deleted.
    static var installedHookURL: URL {
        signalHome.appendingPathComponent("signal_hook.py")
    }

    /// The hook script bundled inside Signal.app, copied to `installedHookURL`.
    static var bundledHookScript: URL? {
        Bundle.main.url(forResource: "signal_hook", withExtension: "py")
    }

    private static func command(for status: String, source: String = "") -> String {
        let suffix = source.isEmpty ? "" : " \(source)"
        return "\(marker) /usr/bin/env python3 \"\(installedHookURL.path)\" \(status)\(suffix)"
    }

    // MARK: - Detection / repair

    /// True when Signal is wired into every provider that appears to be present
    /// on this machine. Users may have any subset of Claude, Cursor, and Codex.
    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: installedHookURL.path) else {
            return false
        }
        let checks: [() -> Bool] = [
            isProviderDirectoryPresent(claudeDirectoryURL) ? isClaudeInstalled : nil,
            isProviderDirectoryPresent(cursorDirectoryURL) ? isCursorInstalled : nil,
            isProviderDirectoryPresent(codexDirectoryURL) ? isCodexInstalled : nil,
        ].compactMap { $0 }
        return !checks.isEmpty && checks.allSatisfy { $0() }
    }

    private static func isClaudeInstalled() -> Bool {
        guard let settings = try? loadSettings(at: settingsURL),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        return managed.allSatisfy { entry in
            guard let groups = hooks[entry.event] as? [[String: Any]] else { return false }
            return groups.contains { group in
                let matcher = group["matcher"] as? String
                return matcher == entry.matcher && isSignalGroup(group, status: entry.status)
            }
        }
    }

    private static func isCursorInstalled() -> Bool {
        guard let settings = try? loadSettings(at: cursorSettingsURL),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        return managedCursor.allSatisfy { entry in
            guard let entries = hooks[entry.event] as? [[String: Any]] else { return false }
            return entries.contains { isSignalCursorEntry($0, status: entry.status) }
        }
    }

    private static func isCodexInstalled() -> Bool {
        guard let settings = try? loadSettings(at: codexHooksURL),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        return managedCodex.allSatisfy { entry in
            guard let groups = hooks[entry.event] as? [[String: Any]] else { return false }
            return groups.contains { group in
                let matcher = group["matcher"] as? String
                return matcher == entry.matcher
                    && isSignalGroup(group, status: entry.status, source: "codex")
            }
        }
    }

    /// If hooks are installed but the stable script went missing or is from an
    /// older app version, restore it so installed commands run the current hook.
    static func repairIfNeeded() {
        guard isInstalled(), stableHookNeedsRepair() else { return }
        try? copyHookToStableLocation()
    }

    private static func stableHookNeedsRepair() -> Bool {
        guard FileManager.default.fileExists(atPath: installedHookURL.path) else {
            return true
        }
        guard let bundled = bundledHookScript,
              let bundledData = try? Data(contentsOf: bundled),
              let installedData = try? Data(contentsOf: installedHookURL) else {
            return false
        }
        return bundledData != installedData
    }

    // MARK: - Install / uninstall

    static func install() throws {
        guard bundledHookScript != nil else { throw InstallError.hookScriptMissing }

        let installClaude = isProviderDirectoryPresent(claudeDirectoryURL)
        let installCursor = isProviderDirectoryPresent(cursorDirectoryURL)
        let installCodex = isProviderDirectoryPresent(codexDirectoryURL)

        guard installClaude || installCursor || installCodex else {
            throw InstallError.noSupportedProviders
        }

        var settings = installClaude ? try loadSettings(at: settingsURL) : [:]
        var cursorSettings = installCursor ? try loadSettings(at: cursorSettingsURL) : [:]
        var codexHooksSettings = installCodex ? try loadSettings(at: codexHooksURL) : [:]

        stripSignalHooks(&settings)
        stripCursorSignalHooks(&cursorSettings)
        stripSignalHooks(&codexHooksSettings)

        if installClaude {
            var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
            for entry in managed {
                var group: [String: Any] = [
                    "hooks": [["type": "command", "command": command(for: entry.status)]]
                ]
                if let matcher = entry.matcher { group["matcher"] = matcher }
                var groups = (hooks[entry.event] as? [[String: Any]]) ?? []
                groups.append(group)
                hooks[entry.event] = groups
            }
            settings["hooks"] = hooks
        }

        if installCursor {
            if cursorSettings["version"] == nil { cursorSettings["version"] = 1 }
            var cursorHooks = (cursorSettings["hooks"] as? [String: Any]) ?? [:]
            for entry in managedCursor {
                var entries = (cursorHooks[entry.event] as? [[String: Any]]) ?? []
                entries.append(["command": command(for: entry.status)])
                cursorHooks[entry.event] = entries
            }
            cursorSettings["hooks"] = cursorHooks
        }

        if installCodex {
            var codexHooks = (codexHooksSettings["hooks"] as? [String: Any]) ?? [:]
            for entry in managedCodex {
                var group: [String: Any] = [
                    "hooks": [[
                        "type": "command",
                        "command": command(for: entry.status, source: "codex"),
                    ]]
                ]
                if let matcher = entry.matcher { group["matcher"] = matcher }
                var groups = (codexHooks[entry.event] as? [[String: Any]]) ?? []
                groups.append(group)
                codexHooks[entry.event] = groups
            }
            codexHooksSettings["hooks"] = codexHooks
        }

        try copyHookToStableLocation()
        if installClaude { try writeSettings(settings, to: settingsURL) }
        if installCursor { try writeSettings(cursorSettings, to: cursorSettingsURL) }
        if installCodex { try writeSettings(codexHooksSettings, to: codexHooksURL) }
    }

    static func uninstall() throws {
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            var settings = try loadSettings(at: settingsURL)
            stripSignalHooks(&settings)
            try writeSettings(settings, to: settingsURL)
        }

        // Only rewrite Cursor's file if it already exists, so uninstalling
        // never creates an empty hooks.json for users who never had Cursor.
        if FileManager.default.fileExists(atPath: cursorSettingsURL.path) {
            var cursor = try loadSettings(at: cursorSettingsURL)
            stripCursorSignalHooks(&cursor)
            try writeSettings(cursor, to: cursorSettingsURL)
        }
        if FileManager.default.fileExists(atPath: codexHooksURL.path) {
            var codex = try loadSettings(at: codexHooksURL)
            stripSignalHooks(&codex)
            try writeSettings(codex, to: codexHooksURL)
        }
        if FileManager.default.fileExists(atPath: installedHookURL.path) {
            try? FileManager.default.removeItem(at: installedHookURL)
        }
    }

    // MARK: - Helpers

    private static func isSignalGroup(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(marker) ?? false }
    }

    private static func isSignalGroup(
        _ group: [String: Any], status: String, source: String = ""
    ) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains {
            guard let command = $0["command"] as? String else { return false }
            return command == HookInstaller.command(for: status, source: source)
        }
    }

    /// A Cursor hook entry is a flat `{ "command": ... }`; ours carries the marker.
    private static func isSignalCursorEntry(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(marker) ?? false
    }

    private static func isSignalCursorEntry(_ entry: [String: Any], status: String) -> Bool {
        (entry["command"] as? String) == command(for: status)
    }

    private static func isProviderDirectoryPresent(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
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

    private static func stripCursorSignalHooks(_ settings: inout [String: Any]) {
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !isSignalCursorEntry($0) }
            if kept.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = kept }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        else { settings["hooks"] = hooks }
    }

    /// Returns the parsed settings, an empty dict if the file is absent, or
    /// throws if the file exists but can't be parsed (so we never overwrite it).
    private static func loadSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url) else {
            throw InstallError.settingsUnreadable
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            throw InstallError.settingsUnreadable
        }
        return dict
    }

    private static func copyHookToStableLocation() throws {
        guard let bundled = bundledHookScript else { throw InstallError.hookScriptMissing }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: signalHome.appendingPathComponent("sessions"),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: installedHookURL.path) {
                try fm.removeItem(at: installedHookURL)
            }
            try fm.copyItem(at: bundled, to: installedHookURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedHookURL.path)
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }

    private static func writeSettings(_ settings: [String: Any], to url: URL) throws {
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
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }
}
