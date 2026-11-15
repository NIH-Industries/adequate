import AppKit
import SwiftUI

@main
struct AdequateApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    // The browser window is AppKit's, owned by the delegate, so it exists
    // however we were launched (including by a link from another app).
    var body: some Scene {
        Settings { EmptyView() }
            .commands { AdequateCommands(spaces: delegate.spaces, delegate: delegate) }
    }
}

/// Menus that list every shortcut. The keys themselves are handled first by
/// SpaceStore's key monitor, so they work even while a page has focus.
struct AdequateCommands: Commands {
    let spaces: SpaceStore
    let delegate: AppDelegate

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Make Adequate the Default Browser") { delegate.makeDefaultBrowser() }
        }
        CommandGroup(before: .toolbar) {
            Button("Toggle Sidebar") { spaces.sidebarShown.toggle() }.keyboardShortcut("s")
        }
        CommandMenu("Tab") {
            Button("New Tab") { spaces.current.newTab() }.keyboardShortcut("t")
            Button("Close Tab") { _ = spaces.current.closeSelected() }.keyboardShortcut("w")
            Divider()
            Button("Open Location") { spaces.current.selectedTab?.focusRequest += 1 }.keyboardShortcut("l")
            Button("Copy Link") { spaces.copyCurrentLink() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Button("Back") { spaces.current.selectedTab?.goBack() }.keyboardShortcut("[")
            Button("Forward") { spaces.current.selectedTab?.goForward() }.keyboardShortcut("]")
            Button("Reload") { spaces.current.selectedTab?.reload() }.keyboardShortcut("r")
            Button("Developer Tools") { spaces.current.selectedTab?.showDeveloperTools() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Zoom In") { spaces.current.selectedTab?.zoom(by: 0.1) }.keyboardShortcut("=")
            Button("Zoom Out") { spaces.current.selectedTab?.zoom(by: -0.1) }.keyboardShortcut("-")
            Button("Actual Size") { spaces.current.selectedTab?.zoom(by: nil) }.keyboardShortcut("0")
            Divider()
            Button("Previous Tab") { spaces.current.selectAdjacentTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { spaces.current.selectAdjacentTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Text("Recent Tabs: ⌃Tab / ⌃⇧Tab")
            Text("Tab 1–8: ⌘1–⌘8, Last Tab: ⌘9")
        }
        CommandMenu("Space") {
            Button("New Space…") { spaces.prompt = .new }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Rename Space…") { spaces.prompt = .rename(spaces.selected) }
            Button("Delete Space…") { spaces.prompt = .delete(spaces.selected) }
            Divider()
            Text("Switch Space: ⌃1–⌃9")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let spaces = SpaceStore()
    private var window: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Take links ourselves, before SwiftUI can turn them into windows.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        spaces.showWindow = { [weak self] in self?.showWindow() }
        _ = CLIToken.value  // make sure the CLI has a token to read
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    /// Html files opened with Adequate, from Finder or `open`.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(spaces.openExternal)
    }

    func makeDefaultBrowser() {
        let app = Bundle.main.bundleURL
        Task {
            // macOS asks you to confirm each of these.
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http")
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .html)
        }
    }

    private func showWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Adequate"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: BrowserView(spaces: spaces).frame(minWidth: 800, minHeight: 600))
            window.setFrameAutosaveName("AdequateMain")
            if !window.setFrameUsingName("AdequateMain") { window.center() }
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        switch url.scheme?.lowercased() {
        case "adequate": spaces.handle(url)
        case "http", "https": spaces.openExternal(url)
        default: break
        }
    }
}
