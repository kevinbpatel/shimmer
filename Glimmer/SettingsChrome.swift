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
}

/// The centred icon-over-label tab strip. Tailscale draws the selected tab as
/// a rounded tinted plate with an accent-coloured glyph and label, and the
/// rest monochrome - no underline, no segmented control.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 19, weight: .regular))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.primary)
                    .frame(minWidth: 74)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selection == tab ? Color.primary.opacity(0.10) : .clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .padding(.horizontal, 12)
    }
}

// MARK: - Rows

/// The gutter every label is right-aligned into. One constant so each pane
/// lines up with the others as the user flips tabs - a per-pane width makes
/// the labels visibly jump.
enum SettingsMetrics {
    static let labelGutter: CGFloat = 168
    static let rowSpacing: CGFloat = 14
    static let contentSpacing: CGFloat = 6
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
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
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 460, alignment: .leading)
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
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A hairline rule between groups, as Tailscale uses above its update block.
struct SettingsRule: View {
    var body: some View {
        Divider().padding(.vertical, 4)
    }
}
