#if os(macOS)
import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private static var appDelegate: AppDelegate?
    private var statusItem: NSStatusItem?
    private let controller = PresenceController()
    private var detailWindow: NSWindow?
    private let statusMenu = NSMenu()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        appDelegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Discord Preference")
        }
        statusMenu.delegate = self
        item.menu = statusMenu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        statusMenu.removeAllItems()

        let status = NSMenuItem(title: controller.discordManager.connectionStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusMenu.addItem(status)

        let song = NSMenuItem(title: controller.musicManager.currentSongTitle, action: nil, keyEquivalent: "")
        song.isEnabled = false
        statusMenu.addItem(song)

        let playback = NSMenuItem(
            title: controller.musicManager.isPlaying ? "Apple Musicで再生中" : "停止中",
            action: nil,
            keyEquivalent: ""
        )
        playback.isEnabled = false
        statusMenu.addItem(playback)

        statusMenu.addItem(.separator())

        let details = NSMenuItem(title: "Details...", action: #selector(openDetailsFromMenu), keyEquivalent: "")
        details.target = self
        statusMenu.addItem(details)

        if controller.discordManager.connectionStatus == "Connected" {
            let disconnect = NSMenuItem(title: "Disconnect", action: #selector(disconnectFromMenu), keyEquivalent: "")
            disconnect.target = self
            statusMenu.addItem(disconnect)
        } else {
            let connect = NSMenuItem(title: "Connect", action: #selector(connectFromMenu), keyEquivalent: "")
            connect.target = self
            connect.isEnabled = !controller.discordToken.isEmpty
            statusMenu.addItem(connect)
        }

        statusMenu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        statusMenu.addItem(quit)
    }

    private func showDetailWindow() {
        if let detailWindow {
            detailWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = DetailWindowFactory.makeWindow(controller: controller)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        detailWindow = window
    }

    @objc private func openDetailsFromMenu() {
        showDetailWindow()
    }

    @objc private func connectFromMenu() {
        controller.connect()
    }

    @objc private func disconnectFromMenu() {
        controller.disconnect()
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === detailWindow {
            controller.musicManager.unloadCurrentArtwork()
            detailWindow = nil
        }
    }
}
#else
import SwiftUI

@main
struct discord_preferenceApp: App {
    @StateObject private var controller = PresenceController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
    }
}
#endif
