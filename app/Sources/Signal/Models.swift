import SwiftUI

/// The traffic-light state of a Claude Code session.
enum SessionStatus: String, Codable {
    case running   // actively working
    case waiting   // blocked waiting for your approval
    case done      // finished its turn, idle

    var color: Color {
        switch self {
        case .running: return .red
        case .waiting: return .yellow
        case .done:    return .green
        }
    }

    /// Colored circle emoji — renders reliably (and in color) in the menu bar.
    var emoji: String {
        switch self {
        case .running: return "🔴"
        case .waiting: return "🟡"
        case .done:    return "🟢"
        }
    }

    var label: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Waiting for you"
        case .done:    return "Done"
        }
    }

    /// Sort/urgency priority: lower comes first (most urgent on top).
    var priority: Int {
        switch self {
        case .waiting: return 0
        case .running: return 1
        case .done:    return 2
        }
    }
}

/// One tracked Claude Code session, mirrored from a state file on disk.
struct Session: Identifiable, Codable {
    let sessionId: String
    let status: SessionStatus
    let project: String
    /// Short excerpt of the session's first prompt, for disambiguation. Optional
    /// so state files written by older hooks still decode.
    let title: String?
    let cwd: String
    let transcriptPath: String
    /// Which client produced the session ("cli", "vscode", "claude_desktop",
    /// "cursor"). Optional so older state files still decode.
    let source: String?
    let updatedAt: Double

    var id: String { sessionId }

    /// Client tag shown in the UI. The plain CLI is the default/expected case
    /// and is left unlabelled to reduce noise; other clients get an explicit tag.
    var sourceLabel: String? {
        switch source {
        case "cursor": return "Cursor"
        case "vscode": return "VS Code"
        case "claude_desktop": return "Claude Desktop"
        default: return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case status
        case project
        case title
        case cwd
        case transcriptPath = "transcript_path"
        case source
        case updatedAt = "updated_at"
    }
}
