import AppKit
import Combine
import SwiftUI

/// A tab popped out into a window of its own: just the page, with the same
/// ⌘L address bar. Pick it in a meeting's screen-share picker to share one
/// tab without the sidebar. Closing the window closes the tab;
/// Tab › Move Tab Back to Main Window puts it back in the sidebar.
@MainActor
final class TabWindow: NSObject, NSWindowDelegate {
    let tab: Tab
    let window: NSWindow
    /// The Space the tab came from, which it goes back to.
    let origin: Space.ID
    private var released = false
    var onClose: (() -> Void)?
    private var titleWatch: AnyCancellable?

    init(tab: Tab, from origin: Space.ID, near parent: NSWindow?) {
        self.tab = tab
        self.origin = origin
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

    /// Closes the window but leaves the tab running, to go back in the sidebar.
    func release() {
        released = true
        tab.onClose = nil
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !released { tab.shutDown() }
        onClose?()
    }
}
