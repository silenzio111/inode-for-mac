import AppKit
import SwiftUI

@MainActor private final class OriginalDelegate: NSObject, NSWindowDelegate {
    var minimized = false
    func windowDidMiniaturize(_ notification: Notification) { minimized = true }
}

@main struct WindowCloseTest {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.level = .normal
        window.isReleasedWhenClosed = false
        let original = OriginalDelegate()
        window.delegate = original
        let coordinator = MinimizeOnCloseCoordinator()
        coordinator.install(on: window)
        window.orderFront(nil)
        window.performClose(nil)
        precondition(window.isMiniaturized, "Close must minimize the window")
        precondition(window.delegate === coordinator, "Minimized window must retain its delegate")
        precondition(original.minimized, "Other delegate callbacks must still reach the original delegate")
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        precondition(!window.isMiniaturized, "Reopening must restore the window")
        coordinator.uninstall()
        precondition(window.delegate === original, "Normal window delegate must be restored")
        window.close()
        let hostedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                                    styleMask: [.titled, .closable, .miniaturizable],
                                    backing: .buffered, defer: false)
        hostedWindow.isReleasedWhenClosed = false
        hostedWindow.contentView = NSHostingView(rootView: Text("window test")
            .frame(width: 220, height: 140)
            .background(MinimizeOnClose().frame(width: 0, height: 0)))
        hostedWindow.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            precondition(hostedWindow.delegate is MinimizeOnCloseCoordinator,
                         "The SwiftUI window attachment must install the close handler")
            hostedWindow.performClose(nil)
            let deadline = Date().addingTimeInterval(1)
            while !hostedWindow.isMiniaturized && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            precondition(hostedWindow.isMiniaturized, "The hosted window must minimize")
            hostedWindow.deminiaturize(nil)
            hostedWindow.close()
            app.stop(nil)
        }
        app.run()
        print("Closing minimizes the window without destroying it")
    }
}
