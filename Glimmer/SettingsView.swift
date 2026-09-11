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
            SettingsTabBar(selection: $model.settingsTab)
            Divider()
            switch model.settingsTab {
            case .computers: ComputersTab()
            case .settings: SettingsTabPage()
            case .about: AboutPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Every setting, on one scrolling page. Tailscale keeps one Settings tab
/// rather than a pane per topic, and the gutter labels ("Resolution:",
/// "Bitrate:") do the grouping that a sidebar would otherwise do; rules
/// separate the broader areas.
private struct SettingsTabPage: View {
    var body: some View {
        SettingsPageBody {
            StreamPane()
            SettingsRule()
            VideoPane()
            SettingsRule()
            AudioPane()
            SettingsRule()
            ShortcutsPane()
            SettingsRule()
            AppPane()
        }
    }
}
