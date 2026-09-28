import AppKit
import SwiftUI

@MainActor private final class OriginalDelegate: NSObject, NSWindowDelegate {
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
        var closeCount = 0
        let coordinator = HideOnCloseCoordinator { closeCount += 1 }
        coordinator.install(on: window)
        window.orderFront(nil)
        window.performClose(nil)
        precondition(closeCount == 1, "Close must notify the app that the window was hidden")
        precondition(!window.isVisible, "Close must hide the window")
        precondition(!window.isMiniaturized, "Close must not leave a minimized window in the Dock")
        precondition(window.delegate === coordinator, "Hidden window must retain its delegate")
        window.makeKeyAndOrderFront(nil)
        precondition(window.isVisible, "The menu bar can reopen the hidden window")
        app.activate(ignoringOtherApps: true)
        window.miniaturize(nil)
        let minimizeDeadline = Date().addingTimeInterval(1)
        while !window.isMiniaturized && Date() < minimizeDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(window.isMiniaturized, "The yellow button must still minimize the window")
        window.deminiaturize(nil)
        coordinator.uninstall()
        precondition(window.delegate === original, "Normal window delegate must be restored")
        window.close()
        let hostedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                                    styleMask: [.titled, .closable, .miniaturizable],
                                    backing: .buffered, defer: false)
        hostedWindow.isReleasedWhenClosed = false
        var hostedCloseCount = 0
        hostedWindow.contentView = NSHostingView(rootView: Text("window test")
            .frame(width: 220, height: 140)
            .background(HideOnClose(onClose: { hostedCloseCount += 1 }).frame(width: 0, height: 0)))
        hostedWindow.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        var hostedChecked = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            precondition(hostedWindow.delegate is HideOnCloseCoordinator,
                         "The SwiftUI window attachment must install the close handler")
            hostedWindow.performClose(nil)
            precondition(hostedCloseCount == 1, "The hosted window must report a red close")
            precondition(!hostedWindow.isVisible, "The hosted window must hide")
            precondition(!hostedWindow.isMiniaturized, "The hosted window must not minimize")
            hostedWindow.makeKeyAndOrderFront(nil)
            precondition(hostedWindow.isVisible, "The hosted window must reopen")
            hostedWindow.close()
            hostedChecked = true
        }
        let deadline = Date().addingTimeInterval(3)
        while !hostedChecked && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(hostedChecked, "The hosted window check must finish promptly")
        print("Red close hides the window; yellow minimize remains available")
    }
}
