import Foundation
import SwiftUI

/// Loads and keeps in sync the set of live Claude Code sessions by watching the
/// state directory the Signal hook writes to.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    private let directory: URL
    private let staleAfter: TimeInterval
    private var watcher: DirectoryWatcher?
    private var pruneTimer: Timer?

    /// - Parameter staleAfter: a session whose state file hasn't been updated in
    ///   this many seconds is treated as dead (e.g. its terminal was force-closed
    ///   before `SessionEnd` could fire) and dropped.
    init(directory: URL = SessionStore.defaultDirectory,
         staleAfter: TimeInterval = 12 * 60 * 60) {
        self.directory = directory
        self.staleAfter = staleAfter
        start()
    }

    nonisolated static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["SIGNAL_STATE_DIR"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".signal/sessions")
    }

    private func start() {
        reload()
        // The outer closures capture nothing; only the inner Task captures self
        // (weakly), which keeps the hop onto the main actor concurrency-safe.
        watcher = DirectoryWatcher(url: directory) {
            Task { @MainActor [weak self] in self?.reload() }
        }
        watcher?.start()
        // Periodic re-scan as a fallback so stale sessions age out even when no
        // filesystem event fires.
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
    }

    func reload() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else {
            sessions = []
            return
        }

        let now = Date().timeIntervalSince1970
        let decoder = JSONDecoder()
        var loaded: [Session] = []

        for url in urls where url.pathExtension == "json"
            && !url.lastPathComponent.hasPrefix(".") {
            guard let data = try? Data(contentsOf: url),
                  let session = try? decoder.decode(Session.self, from: data) else { continue }

            if now - session.updatedAt > staleAfter {
                try? fm.removeItem(at: url)
                continue
            }
            loaded.append(session)
        }

        loaded.sort { lhs, rhs in
            if lhs.status.priority != rhs.status.priority {
                return lhs.status.priority < rhs.status.priority
            }
            return lhs.project.localizedCaseInsensitiveCompare(rhs.project) == .orderedAscending
        }

        sessions = loaded
    }

    /// The most urgent status across all sessions, for the compact menu bar glyph.
    var dominantStatus: SessionStatus? {
        sessions.map(\.status).min(by: { $0.priority < $1.priority })
    }
}
