import AppKit
import Combine
import SwiftUI
import Security
import Foundation
import WebKit

/// A Space is a separate browsing identity: its own tabs, and its own cookies,
/// storage and logins kept in a persistent WebKit data store named by `id`,
/// or, for a throwaway Space, held in memory and gone when Adequate quits.
struct Space: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    /// Optional only so spaces.json from before colours still loads;
    /// SpaceStore fills them in on launch.
    var color: SpaceColor?
    var emoji: String?
    /// Sites asked about notifications, and whether they may show them.
    var notifications: [String: Bool]?
    /// Logins, storage and history never touch the disk, so nothing else
    /// running as you can read them. Optional so older spaces.json loads.
    var throwaway: Bool?

    var isThrowaway: Bool { throwaway == true }
    var tint: Color { (color ?? .blue).color }
    var symbol: String { emoji ?? String(name.prefix(1)).uppercased() }
}

/// The colour a Space wears, saved as one of the swatch names ("teal") or a
/// custom "#rrggbb" picked from the colour panel or brought over from Arc.
struct SpaceColor: RawRepresentable, Codable, Hashable, Identifiable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let pink = Self(rawValue: "pink"), red = Self(rawValue: "red"),
        orange = Self(rawValue: "orange"), yellow = Self(rawValue: "yellow"),
        green = Self(rawValue: "green"), mint = Self(rawValue: "mint"),
        teal = Self(rawValue: "teal"), blue = Self(rawValue: "blue"),
        indigo = Self(rawValue: "indigo"), purple = Self(rawValue: "purple"),
        brown = Self(rawValue: "brown"), gray = Self(rawValue: "gray")

    /// The named colours offered in the Space dialog.
    static let swatches: [Self] = [.pink, .red, .orange, .yellow, .green, .mint,
                                   .teal, .blue, .indigo, .purple, .brown, .gray]

    /// A custom colour, kept as sRGB hex.
    init(_ color: Color) {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
        let byte = { (c: CGFloat) in Int((min(max(c, 0), 1) * 255).rounded()) }
        rawValue = String(format: "#%02x%02x%02x",
                          byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    var id: String { rawValue }
    var isCustom: Bool { rawValue.hasPrefix("#") }

    var color: Color {
        switch rawValue {
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "blue": .blue
        case "indigo": .indigo
        case "purple": .purple
        case "brown": .brown
        case "gray": .gray
        default:
            if isCustom, rawValue.count == 7, let value = UInt32(rawValue.dropFirst(), radix: 16) {
                Color(.sRGB, red: Double(value >> 16 & 0xff) / 255,
                      green: Double(value >> 8 & 0xff) / 255, blue: Double(value & 0xff) / 255)
            } else {
                .blue
            }
        }
    }
}

enum SpaceLook {
    static let emoji = ["🏠", "💼", "🦄", "🌈", "🍉", "🪩", "🌵", "🐙", "🍄", "🚀", "🌻", "🐝", "🎸", "🍒", "🐳", "🔮"]

    /// A colour and emoji no other Space has yet, while there are any left.
    static func fresh(avoiding taken: [Space], name: String) -> (SpaceColor, String) {
        let colors = Set(taken.compactMap(\.color))
        let emojis = Set(taken.compactMap(\.emoji))
        let color = SpaceColor.swatches.first { !colors.contains($0) }
            ?? SpaceColor.swatches[taken.count % SpaceColor.swatches.count]
        let lower = name.lowercased()
        let guess = lower.contains("home") ? "🏠" : lower.contains("work") ? "💼" : nil
        let emoji = guess.flatMap { emojis.contains($0) ? nil : $0 }
            ?? emoji.first { !emojis.contains($0) }
            ?? emoji[taken.count % emoji.count]
        return (color, emoji)
    }
}

/// The live state of one Space: its data store and its tabs.
@MainActor
final class SpaceState: ObservableObject {
    @Published var space: Space
    private(set) var dataStore: WKWebsiteDataStore
    @Published private(set) var tabs: [Tab] = []
    @Published var selectedTabID: Tab.ID? {
        willSet {
            // Picture the tab we're leaving while it's still on screen.
            if newValue != selectedTabID { selectedTab?.captureSnapshot() }
        }
        didSet { if let id = selectedTabID { touch(id) } }
    }

    /// Tab ids, most recently used first. Ctrl-Tab walks this order.
    private var mru: [Tab.ID] = []
    /// While Control is held after ⌃Tab: the tabs in the switcher, most
    /// recent first (frozen as the cycle began), and which one is picked.
    @Published private(set) var cycleOrder: [Tab.ID] = []
    @Published private(set) var cycleIndex: Int?
    var isCycling: Bool { cycleIndex != nil }
    var cycleTabs: [Tab] { cycleOrder.compactMap { id in tabs.first { $0.id == id } } }
    var cycleTarget: Tab.ID? { cycleIndex.flatMap { cycleOrder.indices.contains($0) ? cycleOrder[$0] : nil } }
    /// Camera and microphone allowed for sites in this Space, until Adequate quits.
    let permissions = SitePermissions()
    /// Pages visited in this Space, for address bar suggestions.
    private(set) var history: History
    /// Passes each tab's sound changes up, so the Space's dot can show them.
    private var soundWatches: [Tab.ID: AnyCancellable] = [:]

    var audibleTabs: [Tab] { tabs.filter(\.isPlayingAudio) }

    init(space: Space) {
        self.space = space
        dataStore = Self.store(for: space)
        history = History(space: space.id, persistent: !space.isThrowaway)
    }

    private static func store(for space: Space) -> WKWebsiteDataStore {
        // Each nonPersistent() is a store of its own, so throwaway Spaces
        // don't share logins with each other either.
        space.isThrowaway ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: space.id)
    }

    /// Closes the tabs and starts the Space over with nothing: no logins,
    /// storage, history or site permissions. Only makes sense for a throwaway
    /// Space; a kept one would just get its saved logins back.
    func forgetEverything() {
        closeAll()
        permissions.allowed = []
        if space.notifications != nil {
            space.notifications = nil
            persist?()
        }
        dataStore = Self.store(for: space)
        history = History(space: space.id, persistent: !space.isThrowaway)
    }

    /// Switches between kept and throwaway. Either way the tabs close, since
    /// they're tied to the old store. Going throwaway erases what was saved.
    func setThrowaway(_ throwaway: Bool) {
        guard throwaway != space.isThrowaway else { return }
        space.throwaway = throwaway ? true : nil
        let id = space.id
        forgetEverything()
        if throwaway { Self.eraseSaved(id) }
    }

    /// Erases a Space's saved logins, storage and history from disk.
    static func eraseSaved(_ id: Space.ID) {
        History.erase(space: id)
        Task {
            // The data store can only go once nothing holds it any more,
            // and closed web views take a moment to let go.
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: id)
                    return
                } catch {}
            }
        }
    }

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }

    /// Opens a tab and selects it, unless `background`, when it goes in
    /// behind the current one.
    @discardableResult
    func newTab(configuration: WKWebViewConfiguration? = nil, background: Bool = false) -> Tab {
        let config = configuration ?? {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = dataStore
            // Lets video players (YouTube, Netflix) go full screen.
            config.preferences.isElementFullscreenEnabled = true
            // Look like Safari so sites that sniff the user agent don't refuse us.
            config.applicationNameForUserAgent = "Version/27.0 Safari/605.1.15"
            // Undocumented but long-standing: adds Inspect Element to the
            // context menu and lets Tab.showDeveloperTools open the inspector.
            config.preferences.setValue(true, forKey: "developerExtrasEnabled")
            // Camera and microphone for pages (getUserMedia), off by default in a
            // WKWebView. Private switches: if they go, video calls just can't start.
            if config.preferences.responds(to: Selector(("_setMediaDevicesEnabled:"))) {
                config.preferences.setValue(true, forKey: "mediaDevicesEnabled")
            }
            if config.responds(to: Selector(("_setMediaCaptureEnabled:"))) {
                config.setValue(true, forKey: "mediaCaptureEnabled")
            }
            MediaWatch.install(in: config, for: self)
            PageNotifications.install(in: config, for: self)
            installScripts(in: config.userContentController)
            return config
        }()
        let tab = Tab(configuration: config)
        tab.permissions = permissions
        tab.history = history
        // A pop-up or target=_blank link: WebKit loads its page into this tab.
        if configuration != nil { tab.isBlank = false }
        tab.onOpenTab = { [weak self] configuration in
            self?.newTab(configuration: configuration).webView
        }
        tab.onClose = { [weak self, weak tab] in
            if let tab { self?.close(tab.id) }
        }
        tab.onOpenInBackground = { [weak self] url in
            self?.newTab(background: true).load(url: url)
        }
        soundWatches[tab.id] = tab.$isPlayingAudio.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
        if background, let current = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: current + 1)
            mru.insert(tab.id, at: min(1, mru.count))
        } else {
            tabs.append(tab)
            selectedTabID = tab.id
        }
        return tab
    }

    /// ⌘1..⌘8 pick a tab by position; ⌘9 always the last.
    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        if tabs.indices.contains(index) { selectedTabID = tabs[index].id }
    }

    /// The tab above or below the selected one in the sidebar, wrapping.
    func selectAdjacentTab(_ offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        selectedTabID = tabs[(current + offset + tabs.count) % tabs.count].id
    }

    func closeAll() {
        tabs.forEach { $0.webView.stopLoading() }
        tabs = []
        soundWatches = [:]
        mru = []
        selectedTabID = nil
    }

    func close(_ id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].webView.stopLoading()
        tabs.remove(at: index)
        soundWatches[id] = nil
        mru.removeAll { $0 == id }
        if selectedTabID == id { selectedTabID = mru.first }
    }

    /// Saves the Spaces, set by SpaceStore.
    var persist: (() -> Void)?

    private func installScripts(in controller: WKUserContentController) {
        controller.removeAllUserScripts()
        controller.addUserScript(MediaWatch.userScript)
        controller.addUserScript(PageNotifications.script(decisions: space.notifications ?? [:]))
    }

    /// Forgets everything a site has been allowed or refused in this Space,
    /// notifications included, and reloads its tabs so it can ask afresh.
    func resetPermissions(for site: String) {
        permissions.forget(site: site)
        if space.notifications?[site] != nil {
            space.notifications?[site] = nil
            persist?()
            var seen: Set<ObjectIdentifier> = []
            for tab in tabs {
                let controller = tab.webView.configuration.userContentController
                if seen.insert(ObjectIdentifier(controller)).inserted { installScripts(in: controller) }
            }
        }
        for tab in tabs where tab.site == site {
            tab.forgetRefusals()
            tab.webView.reload()
        }
    }

    /// Remembers a site's answer, tells its open pages, and gives later pages the new script.
    func setNotifications(_ allowed: Bool, for site: String) {
        space.notifications = (space.notifications ?? [:]).merging([site: allowed]) { $1 }
        persist?()
        if allowed { Notifier.shared.requestAuthorization() }
        var seen: Set<ObjectIdentifier> = []
        for tab in tabs {
            let controller = tab.webView.configuration.userContentController
            if seen.insert(ObjectIdentifier(controller)).inserted { installScripts(in: controller) }
            let host = site.split(separator: ":").first.map(String.init) ?? site
            tab.webView.evaluateJavaScript(
                "location.hostname === '\(host)' && window.__adequateNotify?.('permission', '\(allowed ? "granted" : "denied")')"
            ) { _, _ in }
        }
    }

    /// Takes a tab out of the sidebar, still loaded, to live in a window of its own.
    func detach(_ id: Tab.ID) -> Tab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        mru.removeAll { $0 == id }
        soundWatches[id] = nil
        if selectedTabID == id { selectedTabID = mru.first }
        return tab
    }

    func closeSelected() -> Bool {
        guard let id = selectedTabID else { return false }
        close(id)
        return true
    }

    /// One step of ⌃Tab while Control is held. This only moves the switcher's
    /// pick; the tab changes when Control is let go (`endCycle`). The MRU
    /// order is frozen until then, so repeated presses walk further back.
    func cycle(backward: Bool) {
        if cycleIndex == nil {
            guard mru.count > 1 else { return }
            selectedTab?.captureSnapshot()
            cycleOrder = mru
            cycleIndex = 0
        }
        guard let index = cycleIndex else { return }
        cycleIndex = (index + (backward ? -1 : 1) + cycleOrder.count) % cycleOrder.count
    }

    /// Picks a tab in the switcher directly, e.g. by clicking it.
    func cycle(to id: Tab.ID) {
        if let index = cycleOrder.firstIndex(of: id) { cycleIndex = index }
    }

    /// Control let go: go to the picked tab, which becomes the most recent.
    func endCycle() {
        guard cycleIndex != nil else { return }
        let target = cycleTarget
        cancelCycle()
        if let target, tabs.contains(where: { $0.id == target }) { selectedTabID = target }
    }

    /// Esc, or leaving the Space mid-cycle: close the switcher, stay put.
    func cancelCycle() {
        cycleIndex = nil
        cycleOrder = []
    }

    private func touch(_ id: Tab.ID) {
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
    }
}

@MainActor
final class SpaceStore: ObservableObject {
    /// Where the Spaces are kept, so the `adequate` CLI can list them too.
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Adequate/spaces.json")

    @Published private(set) var states: [SpaceState]
    @Published var selected: Space.ID
    /// The Space dialog showing, if any.
    @Published var prompt: SpacePrompt?
    /// Whether the sidebar of tabs and Spaces is showing (⌘S).
    @Published var sidebarShown = true
    /// A brief message at the bottom of the window, like "Copied link".
    @Published var toast: String?
    private var toastTask: Task<Void, Never>?
    /// Brings the main window back, set once the window has appeared.
    var showWindow: (() -> Void)?
    /// The browser window, so shortcuts meant for it don't fire in others.
    weak var mainWindow: NSWindow?
    private var tabWindows: [TabWindow] = []
    private var keyMonitor: Any?
    private var resignObserver: Any?

    init() {
        var loaded = Self.load()
        if loaded.isEmpty {
            loaded = [Space(id: UUID(), name: "Home"), Space(id: UUID(), name: "Work")]
        }
        // Spaces saved before they had colours and emoji get their own now.
        for index in loaded.indices where loaded[index].color == nil || loaded[index].emoji == nil {
            let others = loaded.enumerated().filter { $0.offset != index }.map(\.element)
            let (color, emoji) = SpaceLook.fresh(avoiding: others, name: loaded[index].name)
            if loaded[index].color == nil { loaded[index].color = color }
            if loaded[index].emoji == nil { loaded[index].emoji = emoji }
        }
        states = loaded.map(SpaceState.init)
        selected = loaded[0].id
        states.forEach { $0.persist = { [weak self] in self?.save() } }
        save()
        installKeyMonitor()
    }

    private static func load() -> [Space] {
        if let data = try? Data(contentsOf: file),
           let spaces = try? JSONDecoder().decode([Space].self, from: data) {
            return spaces
        }
        return []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(states.map(\.space)) else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }

    var current: SpaceState { states.first { $0.space.id == selected } ?? states[0] }

    /// The Space called `name` (ignoring case), created if there isn't one.
    func space(named name: String) -> SpaceState {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let state = states.first(where: { $0.space.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return state
        }
        let (color, emoji) = SpaceLook.fresh(avoiding: states.map(\.space), name: wanted)
        let state = SpaceState(space: Space(id: UUID(), name: wanted, color: color, emoji: emoji))
        state.persist = { [weak self] in self?.save() }
        states.append(state)
        save()
        return state
    }

    /// Handles `adequate://open?token=<t>&space=<name>&url=<url>[&url=<url>..]`: opens each
    /// url as a new tab in that Space, creating the Space if needed, and shows
    /// the last one.
    func handle(_ url: URL) {
        guard url.scheme == "adequate", url.host() == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "token" })?.value == CLIToken.value,
              let name = items.first(where: { $0.name == "space" })?.value,
              !name.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        let state = space(named: name)
        current.cancelCycle()
        selected = state.space.id
        for case let text? in items.filter({ $0.name == "url" }).map(\.value) {
            state.newTab().load(text)
        }
        showWindow?()
        NSApp.activate()
    }

    /// A link from another app (Adequate as default browser), or an html file:
    /// a new tab in the Space you're in.
    func openExternal(_ url: URL) {
        current.newTab().load(url: url)
        showWindow?()
        NSApp.activate()
    }

    /// ⌘⇧C: the current page's address onto the clipboard.
    @discardableResult
    func copyCurrentLink() -> Bool {
        guard let address = current.selectedTab?.address, !address.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        show(toast: "Copied link")
        return true
    }

    func show(toast message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { toast = nil }
        }
    }

    func select(spaceAt index: Int) {
        guard states.indices.contains(index) else { return }
        select(states[index].space.id)
    }

    func select(_ id: Space.ID) {
        guard id != selected else { return }
        current.cancelCycle()
        selected = id
    }

    /// ⇧⌘A: the next tab making sound, in any Space, after the one you're on.
    func showPlayingTab() {
        let playing = states.flatMap { state in state.audibleTabs.map { (state, $0) } }
        guard !playing.isEmpty else { return show(toast: "Nothing's playing") }
        let here = playing.firstIndex { $0.1.id == current.selectedTabID && $0.0 === current }
        let (state, tab) = playing[here.map { ($0 + 1) % playing.count } ?? 0]
        select(state.space.id)
        state.selectedTabID = tab.id
    }

    /// Brings a tab forward wherever it is, for a clicked notification.
    func reveal(_ id: Tab.ID) -> Tab? {
        if let popped = tabWindows.first(where: { $0.tab.id == id }) {
            popped.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return popped.tab
        }
        guard let state = states.first(where: { $0.tabs.contains { $0.id == id } }) else { return nil }
        select(state.space.id)
        state.selectedTabID = id
        showWindow?()
        NSApp.activate()
        return state.selectedTab
    }

    /// Pops a tab out into its own window, e.g. to share just it in a call.
    func openInNewWindow(_ id: Tab.ID, from state: SpaceState) {
        guard let tab = state.detach(id) else { return }
        let window = TabWindow(tab: tab, near: mainWindow)
        window.onClose = { [weak self, weak window] in self?.tabWindows.removeAll { $0 === window } }
        tabWindows.append(window)
    }

    /// Starts a throwaway Space over, logged out of everything.
    func forgetEverything(in id: Space.ID) {
        guard let state = state(id), state.space.isThrowaway else { return }
        state.forgetEverything()
        show(toast: "\(state.space.name) forgot everything")
    }

    func pauseAllMedia() {
        states.flatMap(\.audibleTabs).forEach { $0.pauseMedia() }
    }

    func state(_ id: Space.ID) -> SpaceState? { states.first { $0.space.id == id } }

    func isNameTaken(_ name: String, except id: Space.ID? = nil) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return states.contains {
            $0.space.id != id && $0.space.name.caseInsensitiveCompare(wanted) == .orderedSame
        }
    }

    /// A colour and emoji for a Space about to be made, for the New Space dialog.
    func freshLook(for name: String) -> (SpaceColor, String) {
        SpaceLook.fresh(avoiding: states.map(\.space), name: name)
    }

    func addSpace(named name: String, color: SpaceColor, emoji: String, throwaway: Bool) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !isNameTaken(name) else { return }
        // Made whole here, so a throwaway Space never opens a store on disk.
        let state = SpaceState(space: Space(id: UUID(), name: name, color: color,
                                            emoji: emoji.isEmpty ? nil : emoji,
                                            throwaway: throwaway ? true : nil))
        if state.space.emoji == nil { state.space.emoji = freshLook(for: name).1 }
        state.persist = { [weak self] in self?.save() }
        states.append(state)
        save()
        select(state.space.id)
    }

    func edit(_ id: Space.ID, name: String, color: SpaceColor, emoji: String, throwaway: Bool) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isNameTaken(name, except: id), let state = state(id) else { return }
        state.space.name = name
        state.space.color = color
        if !emoji.isEmpty { state.space.emoji = emoji }
        state.setThrowaway(throwaway)
        objectWillChange.send()
        save()
    }

    /// Removes the Space with its tabs, and erases its cookies and storage.
    func delete(_ id: Space.ID) {
        guard states.count > 1, let index = states.firstIndex(where: { $0.space.id == id }) else { return }
        let state = states[index]
        state.closeAll()
        if selected == id { select(states[index == 0 ? 1 : index - 1].space.id) }
        states.remove(at: index)
        save()
        if !state.space.isThrowaway { SpaceState.eraseSaved(id) }
    }

    func move(_ id: Space.ID, by offset: Int) {
        guard let from = states.firstIndex(where: { $0.space.id == id }) else { return }
        let to = from + offset
        guard states.indices.contains(to) else { return }
        states.swapAt(from, to)
        save()
    }

    // Shortcuts go through a local monitor so they win over the web view
    // and over the window's own ⌘W.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
        // Control's release never arrives once another app has the keyboard.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.states.forEach { $0.cancelCycle() } }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])

        if event.type == .flagsChanged {
            if !flags.contains(.control) { current.endCycle() }
            return event
        }
        // The ⌃Tab switcher is up: Esc backs out, other keys are swallowed.
        if current.isCycling, event.keyCode != 48 {
            if event.keyCode == 53 { current.cancelCycle() }
            return nil
        }
        // Leave dialogs (naming a Space, alerts) their own keys.
        if prompt != nil || event.window?.attachedSheet != nil || event.window?.sheetParent != nil {
            return event
        }

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // A popped-out tab's window gets the page keys; ⌘W closes it as usual.
        if let popped = tabWindows.first(where: { $0.window === event.window })?.tab {
            switch (flags, key) {
            case ([.command], "l"): popped.focusRequest += 1
            case ([.command], "r"): popped.reload()
            case ([.command], "["): popped.goBack()
            case ([.command], "]"): popped.goForward()
            case ([.command, .option], "i"): popped.showDeveloperTools()
            default: return event
            }
            return nil
        }
        if let window = event.window, window !== mainWindow { return event }
        let tab = current.selectedTab
        let tabKey: UInt16 = 48

        if event.keyCode == tabKey, flags.contains(.control), !flags.contains(.command) {
            current.cycle(backward: flags.contains(.shift))
            return nil
        }
        switch (flags, key) {
        case ([.command], "t"): current.newTab()
        case ([.command], "w"): return current.closeSelected() ? nil : event
        case ([.command], "l"): tab?.focusRequest += 1
        case ([.command], "s"): sidebarShown.toggle()
        case ([.command], "r"): tab?.reload()
        case ([.command, .option], "i"): tab?.showDeveloperTools()
        case ([.command], "["): tab?.goBack()
        case ([.command], "]"): tab?.goForward()
        case ([.command], "="), ([.command, .shift], "="), ([.command], "+"), ([.command, .shift], "+"):
            tab?.zoom(by: 0.1)
        case ([.command], "-"): tab?.zoom(by: -0.1)
        case ([.command], "0"): tab?.zoom(by: nil)
        case ([.command, .shift], "c"):
            guard copyCurrentLink() else { return event }
        case ([.command, .option], "{"), ([.command, .shift], "["), ([.command, .shift], "{"):
            current.selectAdjacentTab(-1)
        case ([.command, .option], "}"), ([.command, .shift], "]"), ([.command, .shift], "}"):
            current.selectAdjacentTab(1)
        case ([.command, .shift], "n"): prompt = .new
        case ([.command, .shift], "a"): showPlayingTab()
        case ([.command], _) where Int(key).map { (1...9).contains($0) } == true:
            current.selectTab(number: Int(key)!)
        case ([.control], _) where Int(key).map { (1...9).contains($0) } == true:
            select(spaceAt: Int(key)! - 1)
        default:
            return event
        }
        return nil
    }
}

/// The Space dialogs: making a new one, editing, confirming a delete.
enum SpacePrompt: Identifiable, Equatable {
    case new
    case edit(Space.ID)
    case delete(Space.ID)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let id): "edit-\(id)"
        case .delete(let id): "delete-\(id)"
        }
    }
}

/// A secret only this user can read, which every adequate:// request must carry.
/// Any web page can link to an adequate:// url; without the token it can't make
/// us open a page in one of your logged-in Spaces.
enum CLIToken {
    static let file = SpaceStore.file.deletingLastPathComponent().appendingPathComponent("cli-token")

    @MainActor static let value: String = {
        if let saved = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), saved.count >= 32 {
            return saved
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let manager = FileManager.default
        try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        manager.createFile(atPath: file.path, contents: Data(token.utf8),
                           attributes: [.posixPermissions: 0o600])
        return token
    }()
}

/// What sites may do in this Space until Adequate quits: use the camera or
/// microphone, or open another app. Keys are "<site> <what>". A refusal lives
/// on the tab until its page reloads (Tab.refused), so a mistaken "no" is one
/// reload away from being asked again.
@MainActor
final class SitePermissions {
    var allowed: Set<String> = []

    func forget(site: String) {
        allowed = allowed.filter { !$0.hasPrefix("\(site) ") }
    }
}
