import AppKit
import SwiftUI

@MainActor final class HideOnCloseCoordinator: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private weak var originalDelegate: (any NSWindowDelegate)?
    var onClose: () -> Void

    init(onClose: @escaping () -> Void) { self.onClose = onClose }

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
        sender.orderOut(nil)
        onClose()
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

struct HideOnClose: NSViewRepresentable {
    var onClose: () -> Void

    func makeCoordinator() -> HideOnCloseCoordinator { HideOnCloseCoordinator(onClose: onClose) }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachmentView()
        view.onAttach = { [weak coordinator = context.coordinator] window in coordinator?.install(on: window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onClose = onClose
        if let window = nsView.window { context.coordinator.install(on: window) }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: HideOnCloseCoordinator) {
        coordinator.uninstall()
    }
}
