//
//  SettingsView.swift
//
//  The whole app in one window, shaped like Tailscale's: a centred row of icon
//  tabs at the top, and everything else below it.
//
//    Computers - the PCs sidebar and the selected PC's cover grid, with the
//                add/remove actions along the bottom (Tailscale's Accounts tab)
//    Settings  - one long page of flat gutter rows (Tailscale's Settings tab)
//    About     - the centred identity page
//
//  There is deliberately no `Settings` scene and no second window: a SwiftUI
//  Settings scene IS a separate window, which is the thing being removed here.
//  ⌘, and the App-menu item just select the Settings tab (see GlimmerApp).
//

import AppKit
import SwiftUI

struct AppShell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // The title bar area: the system title is hidden (see
            // WindowChromeTweak) so it can be centred here, clear of the
            // traffic lights, exactly as the reference app has it.
            Text("Shimmer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            SettingsTabBar(selection: $model.settingsTab)
            Divider()
            switch model.settingsTab {
            case .computers: ComputersTab()
            case .stream: StreamTabPage()
            case .general: GeneralTabPage()
            case .about: AboutPane()
            }
        }
        // Waived on the WHOLE stack, not just the title row. Waiving it on the
        // title alone drew that row beside the traffic lights but still let the
        // layout reserve the title bar's 32pt for everything below, so the tab
        // strip began ~40pt lower than the reference app's - all of it empty.
        .ignoresSafeArea(.container, edges: .top)
        // Fixed, not resizable - the window follows the tab.
        .frame(width: SettingsMetrics.windowWidth,
               height: model.settingsTab.windowHeight,
               alignment: .top)
    }
}

/// Every setting, on one scrolling page. Tailscale keeps one Settings tab
/// rather than a pane per topic, and the gutter labels ("Resolution:",
/// "Bitrate:") do the grouping that a sidebar would otherwise do; rules
/// separate the broader areas.
/// Everything about the stream itself - what it looks and sounds like and
/// how it is shown - the way a game's Video / Audio pages read.
private struct StreamTabPage: View {
    var body: some View {
        SettingsPageBody {
            StreamPane()
            SettingsRule()
            VideoPane()
        }
    }
}

/// The controls and the app around the stream: shortcuts, the pad, login,
/// the Wi-Fi helper, troubleshooting, diagnostics.
private struct GeneralTabPage: View {
    var body: some View {
        SettingsPageBody {
            ShortcutsPane()
            SettingsRule()
            AppPane()
        }
    }
}
