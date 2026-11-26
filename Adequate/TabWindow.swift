import AppKit
import Combine
import SwiftUI

/// A tab popped out into a window of its own: just the page, with the same
/// ⌘L address bar. Pick it in a meeting's screen-share picker to share one
/// tab without the sidebar. Closing the window closes the tab.
@MainActor
final class TabWindow: NSObject, NSWindowDelegate {
    let tab: Tab
    let window: NSWindow
    var onClose: (() -> Void)?
    private var titleWatch: AnyCancellable?

    init(tab: Tab, near parent: NSWindow?) {
        self.tab = tab
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingController(rootView: TabPage(tab: tab).frame(minWidth: 400, minHeight: 300))
        // Only the minimum: left to its defaults, the controller shrinks the
        // window to the page's ideal size, which is that minimum.
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1100, height: 760))
        if let parent {
            window.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX + 40, y: parent.frame.maxY - 40))
        } else {
            window.center()
        }
        titleWatch = tab.$title.sink { [weak self] _ in
            MainActor.assumeIsolated { self.map { $0.window.title = $0.tab.displayTitle } }
        }
        // window.close() from the page closes this window.
        tab.onClose = { [weak self] in self?.window.close() }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        tab.shutDown()
        onClose?()
    }
}
