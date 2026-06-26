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
                return "~/.claude/settings.json exists but isn't valid JSON. "
                     + "Fix or remove it, then try again — Signal won't overwrite it."
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
        ("PostToolUseFailure", "*", "running"),
        ("Notification", "permission_prompt", "waiting"),
        ("PermissionRequest", nil, "waiting"),
        ("Stop", nil, "done"),
        ("StopFailure", nil, "done"),
        ("SessionEnd", nil, "end"),
    ]

    /// Unique token embedded in every command we install, so we identify and
    /// remove only our own hooks (never a user's unrelated hook).
    private static let marker = "SIGNAL_HOOK=1"

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
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

    /// True if any Signal-managed hook is present in the settings file.
    static func isInstalled() -> Bool {
        guard let settings = try? loadSettings(),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for groups in hooks.values {
            guard let groups = groups as? [[String: Any]] else { continue }
            if groups.contains(where: isSignalGroup) { return true }
        }
        return false
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

        var settings = try loadSettings()
        stripSignalHooks(&settings)

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

        try copyHookToStableLocation()
        try writeSettings(settings)
    }

    static func uninstall() throws {
        var settings = try loadSettings()
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

    /// Returns the parsed settings, an empty dict if the file is absent, or
    /// throws if the file exists but can't be parsed (so we never overwrite it).
    private static func loadSettings() throws -> [String: Any] {
        let url = settingsURL
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
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }
}
