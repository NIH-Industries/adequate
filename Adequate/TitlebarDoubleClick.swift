import AppKit
import WebKit

/// Double-click the top of the sidebar to zoom the window, as you would a
/// title bar. The window has no title bar of its own (the sidebar and page
/// run right up to the top edge), so macOS never sees these clicks. It does
/// what the system's "Double-click a window's title bar to" setting says:
/// zoom, minimise, or nothing.
@MainActor
final class TitlebarDoubleClick {
    /// How far down from the top edge counts as the title bar.
    private static let height: CGFloat = 36
    private weak var window: NSWindow?
    private var monitor: Any?

    init(window: NSWindow) {
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Never swallows the click: the sidebar still sees it.
    private func handle(_ event: NSEvent) -> NSEvent {
        guard event.clickCount == 2, let window, event.window === window,
              !window.styleMask.contains(.fullScreen),
              window.frame.height - event.locationInWindow.y <= Self.height,
              isTitlebarArea(event.locationInWindow, in: window) else { return event }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "None": break
        case "Minimize": window.miniaturize(nil)
        default: window.zoom(nil)
        }
        return event
    }

    /// The top of the sidebar, but not its buttons, the traffic lights or a page.
    private func isTitlebarArea(_ point: NSPoint, in window: NSWindow) -> Bool {
        if let sidebar = sidebarFrame(in: window), !sidebar.contains(point) { return false }
        var view = window.contentView?.superview?.hitTest(point)
        while let current = view {
            if current is WKWebView || current is NSControl { return false }
            view = current.superview
        }
        return true
    }

    /// The sidebar's frame in window coordinates: the first pane of the
    /// window's split view. Nil if there's no split view to ask, in which case
    /// the whole top edge counts (pages and controls still excluded). Empty
    /// while the sidebar is hidden, so a hidden sidebar claims no clicks.
    private func sidebarFrame(in window: NSWindow) -> NSRect? {
        func firstSplit(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            for sub in view.subviews { if let found = firstSplit(in: sub) { return found } }
            return nil
        }
        guard let content = window.contentView, let split = firstSplit(in: content),
              let first = split.arrangedSubviews.first else { return nil }
        return first.isHidden ? .zero : first.convert(first.bounds, to: nil)
    }
}
