#if os(macOS)
import AppKit
import SwiftUI

enum DetailWindowFactory {
    static func makeWindow(controller: PresenceController) -> NSWindow {
        controller.musicManager.loadCurrentArtworkIfNeeded()

        let hostingController = NSHostingController(
            rootView: ContentView(controller: controller)
                .frame(width: 420, height: 680)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Discord Apple Music Status"
        window.setContentSize(NSSize(width: 420, height: 680))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = true
        return window
    }
}
#endif
