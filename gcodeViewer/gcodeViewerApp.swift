import SwiftUI
import AppKit

@main
struct gcodeViewerApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(state: appDelegate.appState)
                .onAppear {
                    // Restore window frame after the window is on screen.
                    AppDelegate.restoreWindowFrame()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            // Remove the default "New Window" menu item — this is a single-document viewer
            CommandGroup(replacing: .newItem) { }
            // Replaces the standard text editing menu with nothing, effectively removing Cut/Copy/Paste from the Edit menu.
            CommandGroup(replacing: .textEditing) { }
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    /// Single AppState instance shared with ContentView.
    let appState: AppState = AppState()

    private static let frameKey = "windowFrame"

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Attach ourselves as the delegate for the main window so we can
        // intercept move/resize events.
        DispatchQueue.main.async {
            NSApp.mainWindow?.delegate = self
        }
    }

    /// Called by macOS when the user opens a file via Finder "Open With",
    /// drags a file onto the Dock icon, or uses File › Open Recent.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "gcode" }) else { return }
        appState.load(url: url)
    }

    // MARK: NSWindowDelegate — save on every move or resize

    func windowDidMove(_ notification: Notification) {
        saveFrame(notification.object as? NSWindow)
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame(notification.object as? NSWindow)
    }

    // MARK: - Helpers

    private func saveFrame(_ window: NSWindow?) {
        guard let window else { return }
        let f = window.frame
        let dict: [String: Double] = [
            "x": f.origin.x, "y": f.origin.y,
            "w": f.size.width, "h": f.size.height,
        ]
        UserDefaults.standard.set(dict, forKey: AppDelegate.frameKey)
    }

    /// Called from the SwiftUI `.onAppear` — by that point the window exists.
    static func restoreWindowFrame() {
        guard
            let dict = UserDefaults.standard.dictionary(forKey: frameKey),
            let x = dict["x"] as? Double, let y = dict["y"] as? Double,
            let w = dict["w"] as? Double, let h = dict["h"] as? Double
        else { return }

        let frame = NSRect(x: x, y: y, width: w, height: h)

        // Make sure the frame is still on a visible screen before restoring.
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }

        NSApp.mainWindow?.setFrame(frame, display: true)
    }
}
