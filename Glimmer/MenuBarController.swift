//
//  MenuBarController.swift
//
//  The menu bar item and its dropdown, in AppKit: an NSStatusItem whose button
//  carries the label, and a real NSMenu rebuilt from the model every time it
//  opens. The dropdown moved here from a SwiftUI MenuBarExtra for one reason -
//  the header. Tailscale's menu opens on the app's name over its status, and
//  that row is inert: neither a disabled item (which would dim the title) nor
//  a button (which would highlight). An NSMenu can only do that as a custom
//  view on the item (`NSMenuItem.view`), which MenuBarExtra can't host. Same
//  shape as ergodriven-tempo-mac's StatusItemController; the rows themselves
//  are ordinary items, with the checkmarks, key equivalents and enabled states
//  the SwiftUI menu had to fake or forgo.
//
//  The label is native button content (image + title), re-applied whenever
//  the @Observable inputs change - a template image in the status bar tints
//  and highlights the way the system's own items do, which a hosted SwiftUI
//  view would not.
//

import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Width the hosted rows lay out at; the standard items pad out to match.
    private static let menuWidth: CGFloat = 250

    private let model: AppModel
    private let item: NSStatusItem
    private let menu = NSMenu()

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        observeLabel()
    }

    // MARK: - Label

    /// Re-run `applyLabel` whenever anything it read changes. The model's
    /// label properties touch their observable dependencies deliberately
    /// (see `menuBarControllerBattery`), so a pad connecting or draining, a
    /// stream starting, or an error all land here.
    private func observeLabel() {
        withObservationTracking {
            applyLabel()
        } onChange: {
            Task { @MainActor [weak self] in self?.observeLabel() }
        }
    }

    /// Precedence, worst news first:
    ///   error         -> the warning triangle alone (nothing else matters)
    ///   pad connected -> the controller's own glyph + its battery percentage
    ///   streaming     -> play.fill
    ///   idle          -> the Eclipse mark (Assets.xcassets/MenuBarIcon)
    ///
    /// The pad outranks `play.fill` deliberately: a live stream is already
    /// obvious from the screen in front of you, whereas the percentage is the
    /// one number you want mid-session and the one you'd otherwise open a
    /// menu to see. A PlayStation pad gets the bundled DualSense mark with a
    /// STEAM-style battery baked in (see MenuBarBatteryGlyph); anything else
    /// gets Apple's generic controller symbol and the number as the title.
    private func applyLabel() {
        guard let button = item.button else { return }
        button.imagePosition = .imageLeading
        button.title = ""
        if model.nativeStreamError != nil, let symbol = model.menuBarSystemImageName {
            button.image = Self.symbol(symbol)
        } else if let battery = model.menuBarControllerBattery {
            if model.menuBarControllerGlyph == .playStation {
                button.image = Self.asset(MenuBarBatteryGlyph.assetName(
                    forPercent: battery.percent, charging: battery.charging))
            } else {
                button.image = Self.symbol("gamecontroller.fill")
                button.title = "\(battery.percent)%"
            }
        } else if let symbol = model.menuBarSystemImageName {
            button.image = Self.symbol(symbol)
        } else {
            button.image = Self.asset("MenuBarIcon")
        }
    }

    // MARK: - Menu

    /// Rebuilt from the model each time the menu opens, so every row reflects
    /// the moment of opening; nothing here is observed while the menu is up.
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        // The header: the PC's name over its live status, inert.
        let title = model.selectedHost?.displayName ?? "Shimmer"
        let status = model.selectedHost == nil ? "No PC paired" : model.selectedHostStatusLine
        menu.addItem(hosted(MenuHeaderRow(title: title, status: status)))
        menu.addItem(.separator())

        if model.selectedHost != nil {
            if model.isStreaming {
                // ONE row for the live session, named and iconed off the app:
                // "Streaming X" (status, disabled) while the window is up,
                // "Back to X" (the way back) whenever it is hidden - a plain
                // Cmd-Tab-away OR showing in PiP.
                let live = action(model.liveStreamRowTitle, #selector(resumeStream),
                                  image: glyph(model.heroTargetApp)
                                      ?? Self.symbol("arrow.up.left.and.arrow.down.right"))
                live.isEnabled = model.nativeStreamBackgrounded
                menu.addItem(live)
                if !model.nativeStreamPictureInPicture {
                    menu.addItem(action("Picture in Picture", #selector(enterPictureInPicture),
                                        image: Self.symbol("pip.enter")))
                }
                // Ending the stream is a disconnect; this is the way to end
                // the game itself.
                menu.addItem(action("Quit \(model.heroTargetApp?.name ?? "the app")",
                                    #selector(quitStreamAndApp), image: Self.symbol("xmark.circle")))
            } else {
                // Named AND iconed off the app this actually launches - the one
                // you streamed here last, not a fixed "Desktop".
                menu.addItem(action(model.heroActionLabel, #selector(streamHero),
                                    image: glyph(model.heroTargetApp) ?? Self.symbol("play.fill")))
                // The host still has the app up from an earlier disconnect (the
                // hero row above resumes it): offer to end it instead.
                if let running = model.runningAppName {
                    menu.addItem(action("Quit \(running)", #selector(quitRunningApp),
                                        image: Self.symbol("xmark.circle")))
                }
            }
            if model.hosts.count > 1 {
                let switcher = NSMenu()
                for host in model.hosts {
                    let row = action(host.displayName, #selector(switchHost))
                    row.representedObject = host.id
                    row.state = host.id == model.selectedHost?.id ? .on : .off
                    switcher.addItem(row)
                }
                let parent = NSMenuItem(title: "Switch PC", action: nil, keyEquivalent: "")
                parent.image = Self.symbol("desktopcomputer")
                parent.submenu = switcher
                menu.addItem(parent)
            }
        }

        // Stream audio - the stream's own level, not the Mac's. No slider: an
        // NSMenu has no slider item (the Sound extra's is a private view-backed
        // one), so a ladder of 10% steps plus Louder / Quieter is the shape
        // that reads native. Shown whether or not a stream is live, because
        // mute persists: a control that disappears with the session is one the
        // user can't undo before starting the next one.
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Stream Audio"))
        menu.addItem(action(model.streamMuted ? "Unmute" : "Mute", #selector(toggleMute),
                            image: Self.symbol(model.streamMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")))
        // The submenu is the ladder alone: 100% down to 10%, the current rung
        // checked. (Louder / Quieter rows sat above it for a while; two verbs
        // over a list of the same values read as clutter.)
        let volume = NSMenu()
        for level in AppModel.streamVolumeLevels {
            let rung = action("\(Int((level * 100).rounded()))%", #selector(setVolume))
            rung.representedObject = level
            rung.state = model.isSelectedStreamVolume(level) ? .on : .off
            volume.addItem(rung)
        }
        let volumeRow = NSMenuItem(title: "Volume: \(model.streamVolumePercent)%", action: nil, keyEquivalent: "")
        volumeRow.submenu = volume
        menu.addItem(volumeRow)

        // Controller battery charm - whenever a pad reporting battery is
        // connected (sampled on open). The glyph matches the label's so the
        // two read as one thing.
        if let battery = model.menuBarControllerBattery {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Controller"))
            let charm = NSMenuItem(
                title: "\(battery.percent)% battery\(battery.charging ? " · charging" : "")",
                action: nil, keyEquivalent: "")
            if battery.charging {
                charm.image = Self.symbol("battery.100.bolt")
            } else {
                switch model.menuBarControllerGlyph {
                case .playStation: charm.image = Self.asset("DualSenseGlyph", height: 11)
                case .generic: charm.image = Self.symbol("gamecontroller.fill")
                }
            }
            charm.isEnabled = false
            menu.addItem(charm)
        }

        // The window rows and Quit at the bottom - Tailscale's layout, where
        // the window is the exception, not the point. Both open the same
        // tabbed window: Settings on its tab, Open Shimmer on the last one.
        menu.addItem(.separator())
        // Plain text at the left edge, like Tailscale's. macOS 26 decorates a
        // menu item with a gear of its own when its ACTION is named
        // `openSettings` (measured: the title, the ⌘, and the exact standard
        // title are all irrelevant - only that selector name draws one; the
        // 27 SDK adds `preferredImageVisibility`). So the selector is not
        // called that, and neither row carries an image - an empty image
        // would suppress the gear but reserve the image column and indent.
        menu.addItem(action("Settings…", #selector(showSettingsPage), key: ","))
        menu.addItem(action("Open Shimmer", #selector(openWindow)))
        menu.addItem(.separator())
        // No "Check for Updates…" here, by request. Sparkle still checks on
        // its own at launch, and the command stays in the app menu.
        menu.addItem(action("Quit Shimmer", #selector(quit), key: "q", image: Self.symbol("power")))
    }

    // MARK: - Actions

    @objc private func streamHero() {
        model.streamDefaultApp()
        NSApp.activate()
    }

    @objc private func resumeStream() { model.resumeStreamWindow() }
    @objc private func quitStreamAndApp() { model.quitStreamAndApp() }
    @objc private func quitRunningApp() {
        guard let host = model.selectedHost else { return }
        model.quitRunningApp(on: host)
    }
    @objc private func enterPictureInPicture() { model.enterPictureInPicture() }

    @objc private func switchHost(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let host = model.hosts.first(where: { $0.id == id }) else { return }
        model.selectHost(host)
    }

    @objc private func toggleMute() { model.toggleStreamMute() }

    @objc private func setVolume(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? Double else { return }
        model.setStreamVolume(level)
    }

    @objc private func showSettingsPage() {
        AppDelegate.openMainWindow?()
        model.settingsTab = .settings
        NSApp.activate()
    }

    @objc private func openWindow() {
        AppDelegate.openMainWindow?()
        NSApp.activate()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Item helpers

    private func action(_ title: String, _ selector: Selector, key: String = "", image: NSImage? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.image = image
        return item
    }

    private func hosted<Content: View>(_ content: Content) -> NSMenuItem {
        let view = NSHostingView(rootView: content.frame(width: Self.menuWidth))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    /// A library app's glyph as a menu image: an SF Symbol, or the bundled
    /// template art (Steam's mark) at the symbol's size.
    private func glyph(_ app: LibraryApp?) -> NSImage? {
        guard let app else { return nil }
        switch app.glyph {
        case .symbol(let name): return Self.symbol(name)
        case .asset(let name): return Self.asset(name, height: 12)
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Bundled template art; `height` scales it keeping its aspect (the
    /// DualSense mark is authored at the menu bar's 20x14).
    private static func asset(_ name: String, height: CGFloat? = nil) -> NSImage? {
        guard let image = NSImage(named: name)?.copy() as? NSImage else { return nil }
        image.isTemplate = true
        if let height, image.size.height > 0 {
            image.size = NSSize(width: image.size.width * height / image.size.height, height: height)
        }
        return image
    }
}

// MARK: - Hosted rows

/// The PC's name in the menu's own 13pt over its status in the 11pt small
/// size, secondary - Tailscale's header, as measured off it at 2x for
/// ergodriven-tempo-mac's MenuHeaderRow: regular weight (the size and the
/// colour do the work), no extra spacing, cap top 9pt below the panel's edge.
struct MenuHeaderRow: View {
    let title: String
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13))
            Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 1)
        .padding(.bottom, 2)
    }
}
