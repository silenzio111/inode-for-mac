import AppKit
import SwiftUI

@MainActor final class MinimizeOnCloseCoordinator: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private weak var originalDelegate: (any NSWindowDelegate)?

    func install(on window: NSWindow) {
        if self.window !== window, let oldWindow = self.window, oldWindow.delegate === self {
            oldWindow.delegate = originalDelegate
        }
        guard window.delegate !== self else { return }
        originalDelegate = window.delegate
        self.window = window
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.miniaturize(nil)
        return false
    }

    func uninstall() {
        if let window, window.delegate === self { window.delegate = originalDelegate }
        window = nil
        originalDelegate = nil
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if originalDelegate?.responds(to: selector) == true { return originalDelegate }
        return super.forwardingTarget(for: selector)
    }

}

private final class WindowAttachmentView: NSView {
    var onAttach: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.onAttach?(window)
        } }
    }
}

struct MinimizeOnClose: NSViewRepresentable {
    func makeCoordinator() -> MinimizeOnCloseCoordinator { MinimizeOnCloseCoordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachmentView()
        view.onAttach = { [weak coordinator = context.coordinator] window in coordinator?.install(on: window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { context.coordinator.install(on: window) }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: MinimizeOnCloseCoordinator) {
        coordinator.uninstall()
    }
}

@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = sender.windows.first(where: { $0.isMiniaturized }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
