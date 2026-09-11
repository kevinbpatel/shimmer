//
//  SettingsChrome.swift
//
//  The settings vocabulary, modelled on Tailscale for macOS: a centred row of
//  icon tabs at the top of the SAME window, then flat two-column rows - the
//  label right-aligned in a fixed gutter, its controls left-aligned beside it,
//  explanatory copy underneath in grey. No sidebar, no grouped cards, no
//  separate Settings window.
//
//  Why this shape rather than SwiftUI's `Form(.grouped)`: grouped Form puts
//  every Section in its own rounded card, so a pane made of one- and two-row
//  sections reads as a stack of disconnected plates. Tailscale's gutter does
//  the grouping instead - the label names a group and its rows sit together
//  without any box - which is why a dense pane still scans.
//

import SwiftUI

// MARK: - Tabs

/// The pages the settings view can show. Raw values are persisted as the
/// remembered tab, so leave them alone when renaming a title.
enum SettingsTab: String, CaseIterable, Identifiable {
    case computers, settings, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .computers: return "Computers"
        case .settings: return "Settings"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .computers: return "display"
        case .settings: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }

    /// Window height for this tab, matching the reference app's behaviour of
    /// resizing itself to the page rather than being dragged.
    /// CONTENT height for this tab. The reference app's windows are 528 / 588
    /// / 540; macOS adds its 32pt title bar on top of whatever the content
    /// asks for, even with `.fullSizeContentView`, so subtract it here.
    var windowHeight: CGFloat {
        switch self {
        case .computers: return 528 - 32
        case .settings: return 588 - 32
        case .about: return 540 - 32
        }
    }
}

/// The centred icon-over-label tab strip. Tailscale draws the selected tab as
/// a rounded tinted plate with an accent-coloured glyph and label, and the
/// rest monochrome - no underline, no segmented control.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    /// macOS desaturates window chrome when the window is not frontmost, and
    /// the reference app's tabs do exactly that. Without this the selected tab
    /// stayed vivid blue on an inactive window, which is what made the two
    /// headers look so different side by side.
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 17, weight: .regular))
                            .frame(height: 19)
                        Text(tab.title)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(tint(for: tab))
                    .frame(minWidth: 58)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selection == tab ? plateFill : .clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(selection == tab
                                                  ? Color.primary.opacity(0.13) : .clear,
                                                  lineWidth: 1))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
        .padding(.horizontal, 12)
    }

    private var isActive: Bool { activeState != .inactive }

    private func tint(for tab: SettingsTab) -> Color {
        guard selection == tab else { return isActive ? .primary : .secondary }
        return isActive ? Color.accentColor : .secondary
    }

    private var plateFill: Color {
        isActive ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.08)
    }
}

// MARK: - Rows

/// The gutter every label is right-aligned into. One constant so each pane
/// lines up with the others as the user flips tabs - a per-pane width makes
/// the labels visibly jump.
enum SettingsMetrics {
    /// Measured off Tailscale's own Settings window (600x588 points, captured
    /// and sampled pixel by pixel):
    ///   * gutter labels right-align at x=168, controls start at x=180 (gap 12)
    ///   * the checkbox is 18pt; its label starts 7pt after it, at x=204
    ///   * explanatory notes align with the checkbox LABEL, not the checkbox -
    ///     they start at x=203, i.e. 23pt into the control column
    ///   * notes wrap by x=532, so ~330pt of measure
    ///   * checkbox rows sit on a 25pt rhythm (18pt control + 7pt)
    ///   * trailing buttons right-align 41pt from the window edge
    static let labelGutter: CGFloat = 168
    static let labelGap: CGFloat = 12
    static let noteIndent: CGFloat = 23
    static let noteWidth: CGFloat = 330
    static let noteSize: CGFloat = 11
    static let rowSpacing: CGFloat = 18
    static let contentSpacing: CGFloat = 6
    /// The settings column is a FIXED width, centred in whatever the window
    /// is: 168 + 12 + 380. Tailscale's window is only 600pt wide so its two
    /// columns fill it; letting ours stretch across a library-sized window
    /// left the gutter stranded with an acre of dead space to the right.
    static let columnWidth: CGFloat = 560
    /// The reference window's exact width, and its per-tab heights. It is not
    /// resizable - the zoom and minimise buttons are disabled - and the height
    /// changes with the tab rather than the user dragging it.
    static let windowWidth: CGFloat = 600
}

/// One labelled group: the label sits in the right-aligned gutter, everything
/// in `content` stacks to its right. Pass `nil` to continue the previous
/// group's column without repeating its label (Tailscale's "General:" owns
/// three checkboxes this way).
struct SettingsField<Content: View>: View {
    private let label: String?
    private let content: Content

    init(_ label: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.labelGap) {
            Text(label.map { $0.hasSuffix(":") ? $0 : "\($0):" } ?? "")
                .frame(width: SettingsMetrics.labelGutter, alignment: .trailing)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: SettingsMetrics.contentSpacing) {
                content
            }
            Spacer(minLength: 0)
        }
    }
}

/// Explanatory copy under a control. Grey, smaller, and wrapped to a readable
/// measure rather than the full window width.
struct SettingsNote: View {
    private let text: String
    /// Tailscale indents its notes to line up with the checkbox LABEL rather
    /// than the checkbox, so the explanation reads as belonging to the thing
    /// above it. Pass false for a row whose control has no leading glyph.
    private let indented: Bool

    init(_ text: String, indented: Bool = true) {
        self.text = text
        self.indented = indented
    }

    var body: some View {
        Text(text)
            .font(.system(size: SettingsMetrics.noteSize))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: SettingsMetrics.noteWidth, alignment: .leading)
            .padding(.leading, indented ? SettingsMetrics.noteIndent : 0)
    }
}

/// A settings page: the scroll container with the padding every pane shares.
struct SettingsPageBody<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                content
            }
            .frame(width: SettingsMetrics.columnWidth, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A hairline rule between groups, as Tailscale uses above its update block.
struct SettingsRule: View {
    var body: some View {
        Divider().padding(.vertical, 4)
    }
}
