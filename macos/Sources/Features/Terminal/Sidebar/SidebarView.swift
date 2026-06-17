import SwiftUI
import UniformTypeIdentifiers

// MARK: - SidebarTheme

struct SidebarTheme: Equatable {
    let background: Color
    let foreground: Color
    let secondaryText: Color
    let activeTabBackground: Color
    let attentionColor: Color

    /// Create from Ghostty terminal colors.
    static func from(background: NSColor, foreground: NSColor) -> SidebarTheme {
        let bgLuminance = background.luminance
        let sidebarBg: Color
        if bgLuminance > 0.5 {
            // Light theme: darken sidebar slightly
            sidebarBg = Color(nsColor: background.darken(by: 0.05))
        } else {
            // Dark theme: lighten sidebar slightly
            sidebarBg = Color(nsColor: background.blended(withFraction: 0.08, of: NSColor.white) ?? background)
        }

        let fg = Color(nsColor: foreground)

        return SidebarTheme(
            background: sidebarBg,
            foreground: fg,
            secondaryText: fg.opacity(0.6),
            activeTabBackground: fg.opacity(0.12),
            attentionColor: .orange
        )
    }

    /// Sensible default when no terminal colors are available yet.
    static var `default`: SidebarTheme {
        SidebarTheme(
            background: Color(nsColor: .controlBackgroundColor),
            foreground: .primary,
            secondaryText: .secondary,
            activeTabBackground: Color.accentColor.opacity(0.12),
            attentionColor: .orange
        )
    }
}

// MARK: - SidebarField

enum SidebarField: String, Hashable {
    case title
    case directory
    case gitBranch = "git-branch"
    case status
    case ports

    static let defaultFields: Set<SidebarField> = [.title, .directory, .gitBranch, .status, .ports]
}

// MARK: - StatusState

/// Semantic state for a status entry, driving its color and animation.
enum StatusState {
    case working   // amber, pulsing — the agent is actively doing work
    case done      // green — finished / your turn
    case error     // red — something failed
    case idle      // gray — waiting / neutral but explicit
    case neutral   // no state set; inherits the muted secondary look

    init(_ raw: String?) {
        switch raw?.lowercased() {
        case "working", "busy", "running", "active", "thinking":
            self = .working
        case "done", "success", "complete", "completed", "ready", "ok":
            self = .done
        case "error", "failed", "fail", "blocked":
            self = .error
        case "idle", "waiting", "paused":
            self = .idle
        default:
            self = .neutral
        }
    }

    /// Whether this state should animate to draw the eye.
    var pulses: Bool { self == .working }

    func color(theme: SidebarTheme) -> Color {
        switch self {
        case .working: return Color(red: 0.95, green: 0.61, blue: 0.07)  // amber
        case .done:    return Color(red: 0.26, green: 0.78, blue: 0.45)  // green
        case .error:   return Color(red: 0.93, green: 0.33, blue: 0.31)  // red
        case .idle:    return theme.secondaryText
        case .neutral: return theme.secondaryText
        }
    }
}

// MARK: - Pulsing

/// Wraps content in a gentle, time-driven breathing pulse when `active`.
/// Uses `TimelineView(.animation)` so the pulse is a pure function of state +
/// time — it starts/stops cleanly across tab refreshes with no animation
/// lifecycle to manage.
private struct Pulsing<Content: View>: View {
    var active: Bool = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        if active {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = (sin(t * 3.2) + 1) / 2  // 0...1
                content()
                    .opacity(0.4 + 0.6 * phase)
                    .scaleEffect(0.82 + 0.18 * phase)
            }
        } else {
            content()
        }
    }
}

// MARK: - SidebarView

/// A vertical sidebar that displays the list of tabs for the current window group.
struct SidebarView: View {
    @ObservedObject var tabManager: SidebarTabManager
    var theme: SidebarTheme
    var fields: Set<SidebarField> = SidebarField.defaultFields

    @AppStorage("SidebarShowCardBorder") private var showCardBorder: Bool = true
    @AppStorage("SidebarDimInactiveColors") private var dimInactiveColors: Bool = false
    @State private var draggingTabID: ObjectIdentifier?
    @State private var dropTargetTabID: ObjectIdentifier?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                    SidebarTabCard(tab: tab, theme: theme, fields: fields, showCardBorder: showCardBorder, dimInactive: dimInactiveColors)
                        .contentShape(Rectangle())
                        .opacity(draggingTabID == tab.id ? 0.4 : 1.0)
                        .overlay(alignment: .top) {
                            if dropTargetTabID == tab.id && draggingTabID != tab.id {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                                    .offset(y: -3)
                            }
                        }
                        .onTapGesture {
                            tabManager.selectTab(tab)
                        }
                        .onDrag {
                            draggingTabID = tab.id
                            return NSItemProvider(object: "\(index)" as NSString)
                        }
                        .onDrop(of: [UTType.text], delegate: TabDropDelegate(
                            tabManager: tabManager,
                            currentTab: tab,
                            currentIndex: index,
                            draggingTabID: $draggingTabID,
                            dropTargetTabID: $dropTargetTabID
                        ))
                        .contextMenu {
                            Button("Rename Tab...") {
                                tabManager.promptRenameTab(tab)
                            }

                            Divider()

                            Menu("Tab Color") {
                                ForEach(TerminalTabColor.allCases, id: \.self) { color in
                                    Button {
                                        tabManager.setTabColor(color, for: tab)
                                    } label: {
                                        Label {
                                            Text(color.localizedName)
                                        } icon: {
                                            Image(nsImage: color.swatchImage(selected: color == tab.tabColor))
                                        }
                                    }
                                }
                            }

                            Toggle("Show Tab Border", isOn: $showCardBorder)
                            Toggle("Dim Inactive Tab Colors", isOn: $dimInactiveColors)

                            Divider()

                            Button("Close Tab") {
                                tabManager.closeTab(tab)
                            }

                            Button("Close Other Tabs") {
                                tabManager.closeOtherTabs(tab)
                            }
                            .disabled(tabManager.tabs.count <= 1)

                            Button("Close Tabs to the Right") {
                                tabManager.closeTabsToTheRight(of: tab)
                            }
                            .disabled({
                                guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return true }
                                return idx >= tabManager.tabs.count - 1
                            }())
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}

// MARK: - TabDropDelegate

private struct TabDropDelegate: DropDelegate {
    let tabManager: SidebarTabManager
    let currentTab: SidebarTabManager.TabItem
    let currentIndex: Int
    @Binding var draggingTabID: ObjectIdentifier?
    @Binding var dropTargetTabID: ObjectIdentifier?

    func dropEntered(info: DropInfo) {
        dropTargetTabID = currentTab.id
    }

    func dropExited(info: DropInfo) {
        if dropTargetTabID == currentTab.id {
            dropTargetTabID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggingTabID != nil && draggingTabID != currentTab.id
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingTabID else { return false }
        guard let sourceIndex = tabManager.tabs.firstIndex(where: { $0.id == draggingTabID }) else { return false }

        tabManager.moveTab(from: sourceIndex, to: currentIndex)

        self.draggingTabID = nil
        self.dropTargetTabID = nil
        return true
    }
}

// MARK: - SidebarTabCard

private struct SidebarTabCard: View {
    let tab: SidebarTabManager.TabItem
    let theme: SidebarTheme
    let fields: Set<SidebarField>
    var showCardBorder: Bool = true
    var dimInactive: Bool = false

    private static let cardRadius: CGFloat = 8

    /// The accent color for the left border strip.
    /// When dimming is enabled, inactive tabs use reduced opacity for a gentle dim.
    /// When no color is set (.none), the strip is fully transparent.
    private var accentColor: Color {
        if let nsColor = tab.tabColor.displayColor {
            let base = Color(nsColor: nsColor)
            return (dimInactive && !tab.isSelected) ? base.opacity(0.55) : base
        }
        return .clear
    }

    /// The border color for the thin card border — always neutral gray.
    private var cardBorderColor: Color {
        Color(nsColor: .separatorColor).opacity(0.3)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left color accent strip — uses UnevenRoundedRectangle so it
            // follows the card's left-side rounding while staying flat on the right.
            UnevenRoundedRectangle(
                topLeadingRadius: Self.cardRadius,
                bottomLeadingRadius: Self.cardRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .fill(accentColor)
            .frame(width: 5)

            VStack(alignment: .leading, spacing: 4) {
                // Title (always shown — attention dot lives here)
                if fields.contains(.title) {
                    HStack(spacing: 6) {
                        Text(tab.displayTitle)
                            .font(.system(size: 12, weight: tab.isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundColor(tab.isSelected ? theme.foreground : theme.secondaryText)

                        Spacer()

                        if tab.needsAttention {
                            Pulsing {
                                Circle()
                                    .fill(theme.attentionColor)
                                    .frame(width: 10, height: 10)
                            }
                        }
                    }
                }

                // Directory name
                if fields.contains(.directory), let dir = tab.directoryName {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                            .foregroundColor(theme.secondaryText)
                        Text(dir)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                // Git branch
                if fields.contains(.gitBranch), let branch = tab.gitBranch {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                            .foregroundColor(theme.secondaryText)
                        Text(branch)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                // Status entries
                if fields.contains(.status), !tab.statusEntries.isEmpty {
                    ForEach(tab.statusEntries, id: \.key) { entry in
                        StatusRowView(entry: entry, theme: theme)
                    }
                }

                // Listening ports detected for processes running in this tab.
                // Each is a clickable chip that opens http://localhost:<port>.
                if fields.contains(.ports), !tab.ports.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                            .font(.system(size: 9))
                            .foregroundColor(theme.secondaryText)
                        ForEach(tab.ports, id: \.self) { port in
                            PortChip(port: port)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, 8)
            .padding(.trailing, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cardRadius))
        .background(
            RoundedRectangle(cornerRadius: Self.cardRadius)
                .fill(tab.isSelected ? theme.activeTabBackground : Color.clear)
        )
        .overlay(
            Group {
                if showCardBorder {
                    RoundedRectangle(cornerRadius: Self.cardRadius)
                        .strokeBorder(cardBorderColor, lineWidth: 1)
                }
            }
        )
    }
}

// MARK: - StatusRowView

/// A single status entry rendered with a colored indicator + colored text,
/// pulsing while the state is `working`.
private struct StatusRowView: View {
    let entry: TabMetadataStore.StatusEntry
    let theme: SidebarTheme

    var body: some View {
        let state = StatusState(entry.state)
        let color = state.color(theme: theme)
        let isNeutral = (state == .neutral)

        HStack(spacing: 5) {
            Pulsing(active: state.pulses) {
                Group {
                    if let icon = entry.icon {
                        Image(systemName: icon)
                            .font(.system(size: 10, weight: .semibold))
                    } else {
                        Circle()
                            .frame(width: 8, height: 8)
                    }
                }
                .foregroundColor(color)
            }

            Text(entry.value)
                .font(.system(size: isNeutral ? 10 : 11, weight: isNeutral ? .regular : .medium))
                .foregroundColor(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

// MARK: - PortChip

/// A clickable `:port` chip that opens http://localhost:<port> in the browser.
private struct PortChip: View {
    let port: Int

    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: "http://localhost:\(port)") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Text(":\(port)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.accentColor)
                .opacity(hovering ? 1.0 : 0.82)
        }
        .buttonStyle(.plain)
        .help("Open http://localhost:\(port)")
        .onHover { inside in
            hovering = inside
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
