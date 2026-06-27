import Foundation

/// Installs, detects, and removes Signal's hooks by editing the user's global
/// ~/.claude/settings.json — the hook system that Claude Code (CLI, VS Code,
/// Claude Desktop) and Cursor's agent all fire. This mirrors install/install.py
/// so a downloaded app can set itself up with one click, no terminal or repo clone.
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
                return "A hooks settings file (~/.claude/settings.json or "
                     + "~/.cursor/hooks.json) exists but isn't valid JSON. Fix or "
                     + "remove it, then try again — Signal won't overwrite it."
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

    private static func command(for status: String) -> String {
        "\(marker) /usr/bin/env python3 \"\(installedHookURL.path)\" \(status)"
    }

    // MARK: - Detection / repair

    /// True only when Signal is wired into both Claude Code and Cursor, so an
    /// existing Claude-only install is re-offered the one-click setup to add the
    /// Cursor hooks.
    static func isInstalled() -> Bool {
        isClaudeInstalled() && isCursorInstalled()
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

    /// If hooks are installed but the stable script went missing (e.g. ~/.signal
    /// was cleaned), restore it so the installed commands don't fail.
    static func repairIfNeeded() {
        guard isInstalled(),
              !FileManager.default.fileExists(atPath: installedHookURL.path) else { return }
        try? copyHookToStableLocation()
    }

    // MARK: - Install / uninstall

    static func install() throws {
        guard bundledHookScript != nil else { throw InstallError.hookScriptMissing }

        var settings = try loadSettings(at: settingsURL)
        var cursorSettings = try loadSettings(at: cursorSettingsURL)

        stripSignalHooks(&settings)
        stripCursorSignalHooks(&cursorSettings)

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

        if cursorSettings["version"] == nil { cursorSettings["version"] = 1 }
        var cursorHooks = (cursorSettings["hooks"] as? [String: Any]) ?? [:]
        for entry in managedCursor {
            var entries = (cursorHooks[entry.event] as? [[String: Any]]) ?? []
            entries.append(["command": command(for: entry.status)])
            cursorHooks[entry.event] = entries
        }
        cursorSettings["hooks"] = cursorHooks

        try copyHookToStableLocation()
        try writeSettings(settings, to: settingsURL)
        try writeSettings(cursorSettings, to: cursorSettingsURL)
    }

    static func uninstall() throws {
        var settings = try loadSettings(at: settingsURL)
        stripSignalHooks(&settings)
        try writeSettings(settings, to: settingsURL)

        // Only rewrite Cursor's file if it already exists, so uninstalling
        // never creates an empty hooks.json for users who never had Cursor.
        if FileManager.default.fileExists(atPath: cursorSettingsURL.path) {
            var cursor = try loadSettings(at: cursorSettingsURL)
            stripCursorSignalHooks(&cursor)
            try writeSettings(cursor, to: cursorSettingsURL)
        }
    }

    // MARK: - Helpers

    private static func isSignalGroup(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(marker) ?? false }
    }

    private static func isSignalGroup(_ group: [String: Any], status: String) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains {
            guard let command = $0["command"] as? String else { return false }
            return command == HookInstaller.command(for: status)
        }
    }

    /// A Cursor hook entry is a flat `{ "command": ... }`; ours carries the marker.
    private static func isSignalCursorEntry(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(marker) ?? false
    }

    private static func isSignalCursorEntry(_ entry: [String: Any], status: String) -> Bool {
        (entry["command"] as? String) == command(for: status)
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
