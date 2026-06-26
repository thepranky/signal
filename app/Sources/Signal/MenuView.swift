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

/// Tracks whether Signal's hooks are installed, for the setup banner.
@MainActor
final class HookState: ObservableObject {
    @Published var installed: Bool = true
    @Published var message: String?

    func refresh() {
        HookInstaller.repairIfNeeded()
        installed = HookInstaller.isInstalled()
    }

    func install() {
        do {
            try HookInstaller.install()
            installed = true
            message = "Hooks installed. Start a session in Claude Code or Cursor to begin tracking."
        } catch {
            message = error.localizedDescription
        }
    }
}

/// The panel shown when the menu bar item is clicked.
struct MenuView: View {
    @ObservedObject var store: SessionStore
    @StateObject private var hooks = HookState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Signal").font(.headline)
                    Text("Agent Sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(store.sessions.count)").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if !hooks.installed {
                SetupBanner(hooks: hooks)
                Divider()
            } else if let message = hooks.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
            }

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
        .onAppear { hooks.refresh() }
    }
}

/// Shown when Signal's hooks aren't yet set up. One click installs them, so
/// users never need a terminal or the install script.
struct SetupBanner: View {
    @ObservedObject var hooks: HookState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finish setup")
                .font(.subheadline.weight(.semibold))
            Text("Signal needs to add hooks so it can see your agent sessions across Claude Code and Cursor.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = hooks.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Set up hooks") { hooks.install() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
                HStack(spacing: 6) {
                    Text(session.project)
                    if let source = session.sourceLabel {
                        Text(source)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                if let title = session.title, !title.isEmpty {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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
