//
//  SettingsView.swift
//
//  Settings as a PAGE INSIDE the main window, not a separate Settings scene:
//  a centred row of icon tabs at the top, the chosen pane below, and a Done
//  button to go back to the library. Tailscale's shape.
//
//  Why not SwiftUI's `Settings` scene: it is by definition its own window, and
//  that is precisely what the owner did not want. Everything the scene gave us
//  for free (⌘, and the App menu item) is re-declared in GlimmerApp's commands
//  and simply flips `model.showSettings`.
//

import AppKit
import SwiftUI

struct SettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ZStack {
                SettingsTabBar(selection: $model.settingsTab)
                HStack {
                    Spacer()
                    Button("Done") { model.showSettings = false }
                        .keyboardShortcut(.escape, modifiers: [])
                        .padding(.trailing, 16)
                }
            }
            Divider()
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch model.settingsTab {
        case .stream: StreamPane()
        case .video: VideoPane()
        case .audio: AudioPane()
        case .input: ShortcutsPane()
        case .pcs: PCsPane()
        case .app: AppPane()
        case .about: AboutPane()
        }
    }
}
