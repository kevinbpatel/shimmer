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

import AppKit
import SwiftUI

/// Opaque chrome: behind-window vibrancy picks up wallpaper and can make this
/// header much brighter than the reference. Keep the light header white and
/// use the system's slightly lighter charcoal surface in dark appearance.
struct SettingsHeaderBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color(nsColor: colorScheme == .dark ? .underPageBackgroundColor : .windowBackgroundColor)
    }
}

// MARK: - Tabs

/// The pages the settings view can show. Raw values are persisted as the
/// remembered tab, so leave them alone when renaming a title.
enum SettingsTab: String, CaseIterable, Identifiable {
    case computers, stream, general, about

    var id: String { rawValue }

    var title: String {
        switch self {
        // The enum case stays `computers` (the --debug-open-settings rawValue
        // and existing references); only the shown name changed to "Servers".
        case .computers: return "Servers"
        case .stream: return "Stream"
        case .general: return "General"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        // A rack, matching the "Servers" name (Sunshine hosts) - and distinct
        // from the "display"/"desktopcomputer" glyph the host rows and menu bar
        // already use for a machine.
        case .computers: return "server.rack"
        // A screen with a play badge: the video you watch, not the Wi-Fi-looking
        // radio waves. The sliders stay with the app-level General page.
        case .stream: return "play.tv"
        case .general: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }

    /// Each tab sizes its window to its content. macOS adds a 32pt title bar
    /// even with `.fullSizeContentView`, so these are content heights. For the
    /// scrolling pages (Stream, General) this is the CEILING: the window
    /// shrinks to fit the rows actually showing, and scrolls past this.
    var windowHeight: CGFloat {
        switch self {
        // Match Tailscale's Accounts window. The apps scroll independently
        // while the latency panel stays anchored above the bottom bar.
        case .computers: return 528 - 32
        // Allow room for the descriptions and CLI row. Unusual expanded
        // controls and diagnostics can still scroll within the page.
        case .stream: return 750 - 32
        case .general: return 744 - 32
        case .about: return 540 - 32
        }
    }
}

/// The centred icon-over-label tab strip. Tailscale draws the selected tab as
/// a rounded neutral plate with an accent-coloured glyph and label, and the
/// rest monochrome - no underline, no segmented control.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    /// macOS desaturates window chrome when the window is not frontmost, and
    /// the reference app's tabs do exactly that. Without this the selected tab
    /// stayed vivid blue on an inactive window, which is what made the two
    /// headers look so different side by side.
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 20, weight: .regular))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(tint(for: tab))
                    // Keep content-sized tabs, using the reference's 20pt
                    // symbols and 12pt labels rather than scaling the window.
                    .padding(.vertical, 5)
                    .padding(.horizontal, 7)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selection == tab ? plateFill : .clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
        guard selection == tab else { return .secondary }
        return isActive ? Color.accentColor : .secondary
    }

    private var plateFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(isActive ? 0.13 : 0.08)
            : (isActive ? Color.white.opacity(0.94) : Color.primary.opacity(0.055))
    }
}

// MARK: - Rows

/// The gutter every label is right-aligned into. One constant so each pane
/// lines up with the others as the user flips tabs - a per-pane width makes
/// the labels visibly jump.
enum SettingsMetrics {
    /// At the reference screenshot's 2× scale, a 72px avatar sits in a
    /// 96px account row. Keep server rows on that same 36 / 48pt rhythm.
    static let sidebarIconSize: CGFloat = 36
    static let sidebarRowHeight: CGFloat = 48
    /// Measured off Tailscale's own Settings window (600x588 points, captured
    /// and sampled pixel by pixel):
    ///   * gutter labels right-align at x=168, controls start at x=180 (gap 12)
    ///   * the checkbox slot is 16pt, centred on the control column; its label
    ///     starts 6pt later, 22pt from the column (x=202 on the 600pt window)
    ///   * the status dot is 10pt and centred in that same slot
    ///   * trailing buttons right-align 20pt from the window edge
    static let labelGutter: CGFloat = 168
    static let labelGap: CGFloat = 12
    /// Between labelled groups. Tailscale separates them with space alone -
    /// no rules - at a ~38pt baseline-to-baseline pitch; 22pt gives that here.
    static let rowSpacing: CGFloat = 22
    static let contentSpacing: CGFloat = 6
    /// Checkbox column shared by toggles, help lines, and status dots.
    static let checkboxSlot: CGFloat = 16
    static let checkboxLabelInset: CGFloat = 22
    static let statusDot: CGFloat = 10
    /// The settings column fills Tailscale's 600pt window from the leading
    /// edge, stopping 20pt short of the trailing edge so Open Settings and
    /// the other trailing buttons land on the reference's button edge.
    /// Centring a shorter column left the buttons stranded in the middle of
    /// the control column, which is what made the status row look unpadded.
    static let columnWidth: CGFloat = 580
    /// The reference window's exact width, and its per-tab heights. It is not
    /// resizable - the zoom and minimise buttons are disabled - and the height
    /// changes with the tab rather than the user dragging it.
    static let windowWidth: CGFloat = 600
    /// The box every popup / slider / segmented control is laid out in. ONE
    /// width for the whole app: the panes used to mix 200 and 260, so the Video
    /// pane's own rows didn't line up with each other, never mind with Stream's.
    static let controlWidth: CGFloat = 260
    /// The box for controls that need more room than a popup - hotkey
    /// recorders, the stats row editor, the DualSense panel.
    static let wideControlWidth: CGFloat = 460
}

extension View {
    /// Lay a control out in the settings column's control box, flush with its
    /// LEFT edge.
    ///
    /// Load-bearing `alignment:`. A bare `.frame(width:)` proposes that width to
    /// the control but does NOT make it take it: AppKit-backed controls that
    /// size to their content - a menu `Picker` (as wide as its longest item), a
    /// `.segmented` picker - stay at their natural width and SwiftUI then
    /// CENTRES them in the box. That is what put every popup on the Stream pane
    /// at a different x: measured on the 600pt window, Resolution started at
    /// 211, Frame rate at 231, the Show-the-stream segmented at 236, the Codec
    /// popup at 203, while the checkboxes and the slider (which does stretch)
    /// sat at 192. `.leading` pins them all to 192; widths stay ragged on the
    /// right, the way macOS's own settings panes look.
    func settingsControl(width: CGFloat = SettingsMetrics.controlWidth) -> some View {
        frame(width: width, alignment: .leading)
    }

    /// A regular push button at the trailing end of a text row (Open
    /// Settings, Show Me How). Regular size, like Tailscale's Manage… - the
    /// small size read as a different control family. macOS 26 draws it 24pt
    /// tall against a 16pt text line, which pushed the rows around it ~4pt
    /// further apart than Tailscale's; laying it out at the text's height and
    /// letting it overhang into the row spacing keeps the text rhythm intact.
    func settingsTrailingButton() -> some View {
        padding(.vertical, -4)
    }

    /// A checkbox directly under another checkbox (no help line between).
    /// Tailscale stacks those at a 25pt pitch; the shared 6pt content spacing
    /// gave 22pt, which read as cramped next to the rows around it.
    func settingsStackedToggle() -> some View {
        padding(.top, 3)
    }

    /// The same flush-left rule for a control that should grow to a ceiling
    /// rather than sit in a fixed box.
    func settingsControl(maxWidth: CGFloat) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
    }
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A permission status row: plain status dot, message, and trailing native action.
struct SettingsNotice<Action: View>: View {
    let message: String
    var tint: Color = .red
    /// True when the row opens its group (nothing above it in the column):
    /// the 4 pt that keeps the button off a description above isn't needed,
    /// and would only widen the gap above the group.
    var firstInGroup = false
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: SettingsMetrics.labelGap) {
            HStack(spacing: 0) {
                Circle().fill(tint)
                    .frame(width: SettingsMetrics.statusDot, height: SettingsMetrics.statusDot)
                    .frame(width: SettingsMetrics.checkboxSlot)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SettingsMetrics.checkboxLabelInset - SettingsMetrics.checkboxSlot)
            }
            Spacer(minLength: SettingsMetrics.labelGap)
            action()
                .settingsTrailingButton()
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A notice sits INSIDE a group, only `contentSpacing` under the line
        // above, so the button's 4pt top overhang nearly touched that help
        // text. Give the overhang back on top; it still saves 4pt below.
        .padding(.top, firstInGroup ? 0 : 4)
    }
}

/// Short explanatory copy aligned beneath a control's text, past its checkbox.
struct SettingsHelp: View {
    let text: String
    var checkbox = true

    init(_ text: String, checkbox: Bool = true) {
        self.text = text
        self.checkbox = checkbox
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, checkbox ? SettingsMetrics.checkboxLabelInset : 0)
            // Tailscale sets its grey copy 18.7pt baseline-to-baseline under
            // the control's text; the shared 6pt content spacing gave 20pt.
            .padding(.top, -1.5)
    }
}

/// The natural height of a `SettingsPageBody`'s content, reported up so the
/// window can end ~28pt under the last row the way Tailscale's does, instead
/// of leaving a fixed-height window half empty when few rows are showing.
struct SettingsPageHeightKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
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
            .padding(.top, 27)
            .padding(.bottom, 28)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: SettingsPageHeightKey.self,
                                           value: proxy.size.height)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
