import SwiftUI
import AppKit

/// Compact glyph shown in the macOS menu bar. Shows one colored circle per
/// session when there are only a few, otherwise a dominant-color summary + count.
struct MenuBarLabel: View {
    @ObservedObject var store: SessionStore

    private let maxCircles = 5

    var body: some View {
        if store.sessions.isEmpty {
            Text("⚪️")
        } else {
            // Sessions are sorted most-urgent first, so the shown circles are
            // the ones that most need your attention.
            let circles = store.sessions.prefix(maxCircles)
                .map { $0.status.emoji }
                .joined()
            let overflow = store.sessions.count - maxCircles
            Text(overflow > 0 ? "\(circles) +\(overflow)" : circles)
        }
    }
}

/// The panel shown when the menu bar item is clicked.
struct MenuView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Claude Sessions").font(.headline)
                Spacer()
                Text("\(store.sessions.count)").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if store.sessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(store.sessions) { session in
                    SessionRow(session: session)
                }
            }

            Divider()

            HStack(spacing: 12) {
                LegendDot(color: .red, text: "Running")
                LegendDot(color: .yellow, text: "Waiting")
                LegendDot(color: .green, text: "Done")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.status.color)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project)
                Text(session.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help(session.cwd)
    }
}

struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }
}
