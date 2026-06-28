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
    @Published var errorMessage: String?
    @Published var showSuccess: Bool = false

    func refresh() {
        HookInstaller.repairIfNeeded()
        installed = HookInstaller.isInstalled()
        if installed { errorMessage = nil }
    }

    func install() {
        do {
            try HookInstaller.install()
            installed = true
            errorMessage = nil
            showSuccess = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                self?.showSuccess = false
            }
        } catch {
            installed = false
            showSuccess = false
            errorMessage = error.localizedDescription
        }
    }

    func dismissSuccess() {
        showSuccess = false
    }
}

/// Reports a subview's height so the session list can be capped without clipping
/// the fixed footer.
private struct TopChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct FooterHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The panel shown when the menu bar item is clicked.
struct MenuView: View {
    @ObservedObject var store: SessionStore
    @StateObject private var hooks = HookState()
    @State private var topChromeHeight: CGFloat = 58
    @State private var footerHeight: CGFloat = 30

    private enum Layout {
        static let width: CGFloat = 300
        static let maxHeight: CGFloat = 480
    }

    /// Vertical space left for the session list once the measured header, optional
    /// banner, and footer are accounted for.
    private var sessionAreaMaxHeight: CGFloat {
        max(0, Layout.maxHeight - topChromeHeight - footerHeight)
    }

    @ViewBuilder
    private var sessionList: some View {
        VStack(spacing: 0) {
            ForEach(store.sessions) { session in
                SessionRow(session: session) {
                    store.clear(session)
                }
            }
        }
    }

    @ViewBuilder
    private var topChrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Signal").font(.headline)
                    Text("Agent Sessions")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(store.sessions.count)")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if !hooks.installed {
                SetupBanner(hooks: hooks)
                Divider()
            } else if hooks.showSuccess {
                HookSuccessRow()
                Divider()
            }
        }
    }

    @ViewBuilder
    private var sessionArea: some View {
        if store.sessions.isEmpty {
            Text("No active sessions")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
        } else {
            ViewThatFits(in: .vertical) {
                sessionList
                ScrollView {
                    sessionList
                }
                .scrollIndicators(.automatic)
            }
            .frame(maxHeight: sessionAreaMaxHeight, alignment: .topLeading)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                LegendDot(color: .red, text: "Running")
                LegendDot(color: .yellow, text: "Waiting")
                LegendDot(color: .green, text: "Done")
                Spacer()
                QuitButton()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topChrome
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: TopChromeHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
            sessionArea
            footer
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: FooterHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
        }
        .frame(width: Layout.width, alignment: .topLeading)
        .onPreferenceChange(TopChromeHeightKey.self) { topChromeHeight = $0 }
        .onPreferenceChange(FooterHeightKey.self) { footerHeight = $0 }
        .onAppear { hooks.refresh() }
        .onDisappear { hooks.dismissSuccess() }
    }
}

/// Shown when Signal's hooks aren't yet set up. One click installs them, so
/// users never need a terminal or the install script.
struct SetupBanner: View {
    @ObservedObject var hooks: HookState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Set up hooks") { hooks.install() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            if let message = hooks.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct HookSuccessRow: View {
    var body: some View {
        Label("Hooks installed", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}

struct QuitButton: View {
    @State private var isHovered = false

    var body: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Text("Quit")
                .foregroundStyle(isHovered ? .primary : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(isHovered ? 0.16 : 0))
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
    }
}

struct SessionRow: View {
    let session: Session
    let onClear: () -> Void
    @State private var isClearHovered = false

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
            Button(action: onClear) {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(isClearHovered ? 0.30 : 0.18))
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isClearHovered ? .primary : .secondary)
                }
                .frame(width: 16, height: 16)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { isClearHovered = $0 }
            .help("Clear this session")
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
