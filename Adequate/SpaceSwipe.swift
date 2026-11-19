import AppKit

/// Swipe sideways on the sidebar with two fingers to move to the next or
/// previous Space, instead of clicking its dot. Only over the sidebar: on a
/// page, a sideways swipe already means back and forward.
///
/// One Space per swipe, like turning a page: fingers moving left go to the
/// Space on the right. Mostly-vertical swipes are left alone, so the tab list
/// still scrolls.
@MainActor
final class SpaceSwipe {
    /// How far the fingers travel, in points, before it counts as a swipe.
    private static let distance: CGFloat = 60
    private let spaces: SpaceStore
    private weak var window: NSWindow?
    private var monitor: Any?
    /// This gesture is ours (mostly sideways), decided on its first movement.
    private var owned: Bool?
    private var travelled: CGFloat = 0
    private var switched = false

    init(window: NSWindow, spaces: SpaceStore) {
        self.window = window
        self.spaces = spaces
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Trackpads and Magic Mouse only: a wheel mouse has no sideways swipe.
        guard event.hasPreciseScrollingDeltas, let window, event.window === window else { return event }
        if event.phase.contains(.began) {
            owned = nil
            travelled = 0
            switched = false
        }
        // Fingers up: whatever the swipe was showing goes away.
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { spaces.swipePreview = nil }
        // The glide after the fingers lift belongs to whoever owned the swipe.
        guard event.momentumPhase.isEmpty else { return owned == true ? nil : event }
        guard let sidebar = window.sidebarFrame, sidebar.contains(event.locationInWindow) else { return event }

        let across = event.scrollingDeltaX, down = event.scrollingDeltaY
        if owned == nil, across != 0 || down != 0 { owned = abs(across) > abs(down) }
        guard owned == true else { return event }

        // Fingers moving left is negative, whichever way "natural scrolling" is set.
        travelled += event.isDirectionInvertedFromDevice ? across : -across
        guard !switched else { return nil }
        let direction = travelled < 0 ? 1 : -1
        let current = spaces.states.firstIndex { $0.space.id == spaces.selected } ?? 0
        let target = current + direction
        guard spaces.states.indices.contains(target) else {
            spaces.swipePreview = nil  // already at the end
            return nil
        }
        let progress = min(abs(travelled) / Self.distance, 1)
        if progress < 1 {
            // Show where it's heading, filling in as the fingers travel.
            spaces.swipePreview = SwipePreview(target: spaces.states[target].space.id,
                                               direction: direction, progress: progress)
        } else {
            switched = true
            spaces.swipePreview = nil
            spaces.select(spaceAt: target)
            let space = spaces.states[target].space
            spaces.show(toast: "\(space.symbol)  \(space.name)")
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        return nil
    }
}

private extension NSWindow {
    /// The sidebar's frame in window coordinates: the first pane of the
    /// window's split view. Nil if there isn't one to ask, and empty while the
    /// sidebar is hidden.
    var sidebarFrame: NSRect? {
        func firstSplit(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            for sub in view.subviews { if let found = firstSplit(in: sub) { return found } }
            return nil
        }
        guard let content = contentView, let split = firstSplit(in: content),
              let first = split.arrangedSubviews.first else { return nil }
        return first.isHidden ? .zero : first.convert(first.bounds, to: nil)
    }
}
