import AppKit
import Foundation
import WebKit

@MainActor
final class Tab: NSObject, ObservableObject, Identifiable, WKUIDelegate, WKNavigationDelegate {
    let id = UUID()
    let webView: WKWebView
    @Published var address = ""
    @Published var title = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    /// Everything on the page came over HTTPS.
    @Published var isSecure = false
    @Published var progress = 0.0
    @Published var favicon: NSImage?
    /// How the page looked when last on screen, for the ⌃Tab switcher.
    @Published private(set) var snapshot: NSImage?
    /// Some frame of the page is playing sound (or would be, if muted).
    @Published private(set) var isPlayingAudio = false
    @Published private(set) var isMuted = false
    /// Bumped to ask the address bar to take focus.
    @Published var focusRequest = 0
    /// The find bar (⌘F) is showing.
    @Published private(set) var findShown = false
    /// Bumped to ask the find field to take focus, with its text selected.
    @Published private(set) var findRequest = 0
    /// What's being looked for, kept while the bar is closed so ⌘G carries on.
    @Published var findText = ""
    @Published private(set) var findResult: FindResult?
    private var findTask: Task<Void, Never>?

    enum FindResult: Equatable {
        case notFound
        /// Found, with how many times the text is on the page, when that's known.
        case found(count: Int?)
    }
    /// True until something is loaded: only a blank tab starts in the address bar.
    var isBlank = true
    /// Pinned: kept in the sidebar across restarts, and it comes back to this
    /// address (not wherever you browsed to in it).
    @Published var pinnedURL: URL?
    /// The name the pin was saved with, shown while it's asleep.
    var pinTitle = ""
    /// A pinned tab whose page isn't loaded (after a restart, or ⌘W): it
    /// loads when it's first shown, so pins cost nothing until used.
    @Published private(set) var isAsleep = false
    var isPinned: Bool { pinnedURL != nil }

    /// Makes this unused tab a sleeping pin.
    func fallAsleep(as pin: Pin) {
        pinnedURL = URL(string: pin.url)
        pinTitle = pin.title
        title = pin.title
        address = pin.url
        isBlank = false
        isAsleep = true
    }

    /// Shown for the first time: load the pinned page.
    func wake() {
        guard isAsleep, let pinnedURL else { return }
        isAsleep = false
        load(url: pinnedURL)
    }

    /// Back to the address this tab was pinned at.
    func returnToPin() {
        if let pinnedURL { load(url: pinnedURL) }
    }

    /// Opens a page that asked for a new window as a tab in the same Space.
    /// It must use the given configuration so `window.opener` keeps working.
    var onOpenTab: ((WKWebViewConfiguration) -> WKWebView?)?
    /// Opens a ⌘-clicked link as a background tab in the same Space.
    var onOpenInBackground: ((URL) -> Void)?
    var onClose: (() -> Void)?
    /// The Space's memory of which sites may use the camera and microphone.
    var permissions: SitePermissions?
    /// The Space's history, which pages loaded here add to.
    var history: History?
    /// In a throwaway Space: its downloads don't record where they came from.
    var isThrowaway = false
    /// A pop-up or target=_blank link opened this tab, not you.
    var openedByPage = false
    /// The page loading now was asked for in the address bar.
    private var typedLoad = false
    private var observations: [NSKeyValueObservation] = []
    private var faviconHost: String?
    /// What this page was refused (camera, opening an app), so it can't keep
    /// asking. Cleared when the page reloads or you go elsewhere.
    private var refused: Set<String> = []
    /// A question about opening another app is showing: further asks wait.
    private var askingToOpen = false
    /// Waiting on the location question that's showing.
    private var locationWaiters: [(Bool) -> Void] = []
    /// The frame with the field you were last in, where ⌘⇧P fills.
    var focusedFrame: WKFrameInfo?
    /// Frames that have told MediaWatch about their media, by the id each
    /// page's script picks, and which of them are playing sound.
    private var mediaFrames: [String: WKFrameInfo] = [:]
    private var audibleFrames: Set<String> = []

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.address = webView.url?.absoluteString ?? "" }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    self?.title = webView.title ?? ""
                    if let url = webView.url { self?.history?.retitle(url, webView.title ?? "") }
                }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progress = webView.estimatedProgress }
            },
            webView.observe(\.hasOnlySecureContent, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isSecure = webView.hasOnlySecureContent }
            },
        ]
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = URL(string: address)?.host() { return host }
        return "New Tab"
    }

    /// From the address bar: go there, then hand the keyboard to the page.
    func load(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedLoad = true
        let url = Self.url(for: text)
        // Only the part after # changed: a plain load would just jump within
        // the page, and pages that read the # once (magic links) never see it.
        if let current = webView.url, url.fragment != nil, Self.withoutFragment(current) == Self.withoutFragment(url) {
            load(url: url)
            webView.reload()
        } else {
            load(url: url)
        }
        focusPage()
    }

    /// Gives the keyboard to the page, so Return reaches its buttons.
    func focusPage() {
        DispatchQueue.main.async { [webView] in
            webView.window?.makeFirstResponder(webView)
        }
    }

    // MARK: Find

    /// ⌘F: shows the find bar, or takes the keyboard back to it.
    func showFind() {
        findShown = true
        findRequest += 1
    }

    /// Esc or the close button: the match is let go, so it isn't left highlighted.
    func hideFind() {
        findShown = false
        findTask?.cancel()
        findResult = nil
        webView.evaluateJavaScript("window.getSelection()?.removeAllRanges()") { _, _ in }
        focusPage()
    }

    /// Typing in the find bar: the first match from where you were, so
    /// adding a letter doesn't skip the match you're looking at.
    func findChanged(_ text: String) {
        findText = text
        findTask?.cancel()
        guard !text.isEmpty else { findResult = nil; return }
        findTask = Task {
            _ = try? await webView.evaluateJavaScript("window.getSelection()?.collapseToStart()")
            await find(backwards: false)
        }
    }

    /// Return, ⌘G (next) or ⇧Return, ⌘⇧G (previous), wrapping around the page.
    func findAgain(backwards: Bool) {
        guard !findText.isEmpty else { return showFind() }
        findTask?.cancel()
        findTask = Task { await find(backwards: backwards) }
    }

    private func find(backwards: Bool) async {
        let text = findText
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        let found = await withCheckedContinuation { done in
            webView.find(text, configuration: configuration) { done.resume(returning: $0.matchFound) }
        }
        guard !Task.isCancelled, text == findText else { return }
        findResult = found ? .found(count: await matchCount(text)) : .notFound
    }

    /// How often the text appears in the page's visible text, counted in our
    /// own script world so the page can't tamper with it. Frames aren't
    /// counted, so this can come up short (or nil) when find still matches.
    private func matchCount(_ text: String) async -> Int? {
        let script = """
            const page = (document.body?.innerText ?? '').toLowerCase();
            const wanted = text.toLowerCase();
            let count = 0;
            for (let at = page.indexOf(wanted); at !== -1; at = page.indexOf(wanted, at + wanted.length)) count++;
            return count;
            """
        let count = try? await webView.callAsyncJavaScript(script, arguments: ["text": text],
                                                          contentWorld: .defaultClient) as? Int
        return count.flatMap { $0 > 0 ? $0 : nil }
    }

    private static func withoutFragment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    func load(url: URL) {
        isBlank = false
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: Self.readAccess(for: url))
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// What a local page may read: its own folder, so a report's images and
    /// styles load, but only itself when it sits loose in a catch-all folder
    /// like Downloads, or a downloaded page could read every file beside it.
    static func readAccess(for file: URL) -> URL {
        let folder = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        let catchAll = [home] + ["Downloads", "Desktop", "Documents", "Library"].map { home.appendingPathComponent($0) }
            + ["/", "/Users", "/tmp", "/private/tmp", "/private/var/tmp", NSTemporaryDirectory()].map(URL.init(fileURLWithPath:))
        let isCatchAll = catchAll.contains { $0.resolvingSymlinksInPath().standardizedFileURL.path == folder.path }
        return isCatchAll ? file : folder
    }

    /// Opens WebKit's Web Inspector for this tab, through WKWebView's private
    /// inspector object. If a macOS update removes it, this does nothing.
    func showDeveloperTools() {
        guard let inspector = webView.value(forKey: "_inspector") as? NSObject else { return }
        let show = Selector(("show"))
        if inspector.responds(to: show) { inspector.perform(show) }
    }

    /// Pictures the page for the ⌃Tab switcher. Only a web view in a window
    /// draws, so this is taken while the tab is showing, e.g. as you leave it.
    func captureSnapshot() {
        guard webView.window != nil, !webView.bounds.isEmpty, !isBlank else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 480
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated {
                if let image { self?.snapshot = image }
            }
        }
    }

    func reload() {
        if isLoading { webView.stopLoading() } else { webView.reload() }
    }
    func goBack() { webView.goBack() }

    // MARK: Sound

    func mediaReport(frame: String, playing: Bool, info: WKFrameInfo) {
        mediaFrames[frame] = info
        if playing { audibleFrames.insert(frame) } else { audibleFrames.remove(frame) }
        isPlayingAudio = !audibleFrames.isEmpty
        // A frame that came along after the tab was muted.
        if isMuted, playing { MediaWatch.setMuted(true, in: webView, frame: info) }
    }

    func toggleMute() {
        isMuted.toggle()
        for info in mediaFrames.values { MediaWatch.setMuted(isMuted, in: webView, frame: info) }
    }

    func pauseMedia() {
        webView.pauseAllMediaPlayback {}
    }

    /// The tab is closing: end its page now. Dropping the tab isn't enough,
    /// because a page keeps running (and playing) for as long as anything
    /// still holds its web view, on screen or not, and SwiftUI can hang on
    /// to a closed tab's views for a while.
    func shutDown() {
        webView.stopLoading()
        Locator.shared.forget(webView)
        webView.pauseAllMediaPlayback {}
        isPlayingAudio = false
        // WebKit's private close, as Safari does: the page and its scripts,
        // timers, media and Web Audio end at once. If it goes, a blank page
        // does nearly the same.
        let close = Selector(("_close"))
        if webView.responds(to: close) {
            webView.perform(close)
        } else {
            webView.loadHTMLString("", baseURL: nil)
        }
    }

    func goForward() { webView.goForward() }
    func zoom(by step: CGFloat?) {
        webView.pageZoom = step.map { min(max(webView.pageZoom + $0, 0.3), 3) } ?? 1
    }

    static func url(for text: String) -> URL {
        if let url = URL(string: text), let scheme = url.scheme,
           ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        if !text.contains(" "), text.contains(".") || text.hasPrefix("localhost"),
           let url = URL(string: (text.hasPrefix("localhost") ? "http://" : "https://") + text) {
            return url
        }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url!
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        onOpenTab?(configuration)
    }

    /// A page wants the camera or microphone (getUserMedia): ask, once per
    /// site per Space while Adequate is open.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let site = Self.site(origin)
        let what = switch type {
        case .camera: "camera"
        case .microphone: "microphone"
        default: "camera and microphone"
        }
        let key = "\(site) \(type.rawValue)"
        if permissions?.allowed.contains(key) == true { return decisionHandler(.grant) }
        if refused.contains(key) { return decisionHandler(.deny) }
        ask("Allow \(site) to use your \(what)?",
            detail: Self.rememberNote,
            buttons: ["Allow", "Don't Allow"], defaultButton: 1) { [weak self] choice in
            self?.remember(key, allowed: choice == 0)
            if choice == 0 { self?.allowAutoplay() }
            decisionHandler(choice == 0 ? .grant : .deny)
        }
    }

    /// A site you let use the camera or microphone may play sound without a
    /// click: a call's voices come through <audio> elements, and WebKit's
    /// autoplay rules sometimes refuse them, leaving a call you join silent.
    /// Private, like Safari's per-site Auto-Play setting: if it goes, calls
    /// are just as they were. This page gets it now; later ones as they load.
    private static let autoplayAllowed = 1 // _WKWebsiteAutoplayPolicyAllow

    private func allowAutoplay() {
        let update = Selector(("_updateWebpagePreferences:"))
        let preferences = WKWebpagePreferences()
        guard preferences.responds(to: Selector(("_setAutoplayPolicy:"))),
              webView.responds(to: update) else { return }
        preferences.setValue(Self.autoplayAllowed, forKey: "autoplayPolicy")
        webView.perform(update, with: preferences)
    }

    /// A page wants to know where you are (PageLocation): asked once per site
    /// per Space, like the camera. Asks that arrive while one is showing
    /// share its answer.
    func askForLocation(site: String, then: @escaping (Bool) -> Void) {
        let key = "\(site) location"
        if permissions?.allowed.contains(key) == true { return then(true) }
        if refused.contains(key) { return then(false) }
        locationWaiters.append(then)
        guard locationWaiters.count == 1 else { return }
        ask("Allow \(site) to use your location?",
            detail: Self.rememberNote,
            buttons: ["Allow", "Don't Allow"], defaultButton: 1) { [weak self] choice in
            guard let self else { return }
            remember(key, allowed: choice == 0)
            let waiters = locationWaiters
            locationWaiters = []
            waiters.forEach { $0(choice == 0) }
        }
    }

    /// A page asked to show notifications.
    func askToNotify(site: String, then: @escaping (Bool) -> Void) {
        ask("Allow \(site) to show notifications?",
            detail: "They appear while Adequate is open, and clicking one brings back this tab.",
            buttons: ["Allow", "Don't Allow"], defaultButton: 1) { then($0 == 0) }
    }

    /// A page wants to share the screen (getDisplayMedia). WebKit's private
    /// delegate method: answer with what macOS's picker should offer
    /// (0 deny, 1 a screen, 2 a window).
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func webView(_ webView: WKWebView, requestDisplayCaptureFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, withSystemAudio: Bool,
                 decisionHandler: @escaping (Int) -> Void) {
        ask("Share your screen with \(Self.site(origin))?",
            detail: "To share one tab, right-click it in the sidebar and choose Open in New Window, then pick that window.",
            buttons: ["Window…", "Entire Screen…", "Cancel"], defaultButton: 2) { choice in
            decisionHandler([2, 1, 0][min(choice, 2)])
        }
    }

    private static func site(_ origin: WKSecurityOrigin) -> String {
        origin.port == 0 ? origin.host : "\(origin.host):\(origin.port)"
    }

    /// An alert on the tab's window; `then` gets the index of the button pressed.
    private static let rememberNote =
        "A yes holds for this site in this Space until Adequate quits; a no until the page reloads. Right-click the tab to reset."

    private func remember(_ key: String, allowed yes: Bool) {
        if yes { permissions?.allowed.insert(key) } else { refused.insert(key) }
    }

    func forgetRefusals() { refused = [] }

    /// The site this tab is on, as permissions are keyed ("host" or "host:port").
    var site: String? {
        guard let url = URL(string: address), let host = url.host(percentEncoded: true) else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// `defaultButton` is the one Return presses: the safe answer, so a page
    /// can't ask just as you're typing and have Return say yes.
    private func ask(_ message: String, detail: String? = nil, buttons: [String], defaultButton: Int = 0,
                     accessory: NSView? = nil, then: @escaping (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        if let detail { alert.informativeText = detail }
        if let accessory {
            alert.accessoryView = accessory
            alert.window.initialFirstResponder = accessory
        }
        buttons.forEach { alert.addButton(withTitle: $0) }
        for (index, button) in alert.buttons.enumerated() {
            button.keyEquivalent = index == defaultButton ? "\r" : index == buttons.count - 1 ? "\u{1b}" : ""
        }
        let index = { (response: NSApplication.ModalResponse) in
            response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        }
        if let window = webView.window {
            alert.beginSheetModal(for: window) { then(index($0)) }
        } else {
            then(index(alert.runModal()))
        }
    }

    /// A page wants to hand a link to another app (Zoom, Slack, Mail). Ask
    /// first, once per site and app per Space, as Safari does: otherwise any
    /// page could launch any app with a URL handler, unprompted.
    private func openInOtherApp(_ url: URL, scheme: String) {
        // adequate:// (and Adequate Dev's adequate-dev://) is for the CLI, never pages.
        guard !["adequate", "adequate-dev"].contains(scheme.lowercased()),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        let site = self.site ?? "This page"
        let name = FileManager.default.displayName(atPath: app.path)
            .replacingOccurrences(of: ".app", with: "")
        let key = "\(site) open \(scheme.lowercased())"
        if permissions?.allowed.contains(key) == true {
            NSWorkspace.shared.open(url)
            return
        }
        if refused.contains(key) { return }
        guard !askingToOpen else { return }
        askingToOpen = true
        ask("Allow \(site) to open \(name)?",
            detail: Self.rememberNote,
            buttons: ["Open \(name)", "Cancel"], defaultButton: 1) { [weak self] choice in
            self?.askingToOpen = false
            self?.remember(key, allowed: choice == 0)
            if choice == 0 { NSWorkspace.shared.open(url) }
        }
    }

    // alert(), confirm() and prompt(): without these WebKit answers for the
    // page at once (confirm() is false), so a delete button that confirms
    // first just does nothing.

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        ask(Self.says(frame), detail: message, buttons: ["OK"]) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        ask(Self.says(frame), detail: message, buttons: ["OK", "Cancel"]) { completionHandler($0 == 0) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        ask(Self.says(frame), detail: prompt, buttons: ["OK", "Cancel"], accessory: field) {
            completionHandler($0 == 0 ? field.stringValue : nil)
        }
    }

    /// Whose question it is: a pop-up from a page can't pass itself off as Adequate.
    private static func says(_ frame: WKFrameInfo) -> String {
        "\(site(frame.securityOrigin)) says"
    }

    /// A page's file field (or a script clicking one): pick what to upload.
    /// Only what you pick goes to the page, and only for that field.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        panel.message = "Choose \(parameters.allowsMultipleSelection ? "files" : "a file") to send to \(Self.site(frame.securityOrigin))"
        panel.prompt = "Upload"
        let finish = { (response: NSApplication.ModalResponse) in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// The context menu's Download Linked File / Download Image. WebKit's
    /// private delegate method: without it those downloads go nowhere.
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreate download: WKDownload) {
        startDownload(download)
    }

    func webViewDidClose(_ webView: WKWebView) {
        // window.close() from a pop-up, e.g. at the end of an OAuth sign-in.
        onClose?()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow, preferences) }
        // mailto:, zoommtg:, slack: and friends belong to other apps.
        if let scheme = url.scheme, !["http", "https", "file", "about", "data", "blob", "javascript"].contains(scheme) {
            openInOtherApp(url, scheme: scheme)
            return decisionHandler(.cancel, preferences)
        }
        // <a download>: save it, even if WebKit could show it.
        if navigationAction.shouldPerformDownload { return decisionHandler(.download, preferences) }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) {
            onOpenInBackground?(url)
            return decisionHandler(.cancel, preferences)
        }
        if navigationAction.targetFrame?.isMainFrame ?? true,
           let host = url.host, permissions?.mayCapture(site: url.port.map { "\(host):\($0)" } ?? host) == true,
           preferences.responds(to: Selector(("_setAutoplayPolicy:"))) {
            preferences.setValue(Self.autoplayAllowed, forKey: "autoplayPolicy")
        }
        decisionHandler(.allow, preferences)
    }

    /// What WebKit can't show (a zip, a dmg), or what the server says to
    /// save (Content-Disposition: attachment), is downloaded instead.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let attachment = disposition.trimmingCharacters(in: .whitespaces).hasPrefix("attachment")
        if !navigationResponse.canShowMIMEType || (navigationResponse.isForMainFrame && attachment) {
            return decisionHandler(.download)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        startDownload(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        startDownload(download)
    }

    private func startDownload(_ download: WKDownload) {
        let page = webView.url.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
        Downloads.shared.track(download, from: page, throwaway: isThrowaway)
        // A link that opened a new tab just to download (target=_blank):
        // nothing's left to show in it, so it goes.
        if openedByPage, webView.backForwardList.currentItem == nil {
            DispatchQueue.main.async { [weak self] in self?.onClose?() }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A fresh page (or a reload) may ask again about anything refused.
        forgetRefusals()
        Locator.shared.forget(webView)
        focusedFrame = nil
        // A new page: the old one's frames and sound are gone. Muting stays with the tab.
        mediaFrames = [:]
        audibleFrames = []
        isPlayingAudio = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { history?.record(url, title: webView.title ?? "", typed: typedLoad) }
        typedLoad = false
        Task { await refreshFavicon() }
        // A moment after loading, once the page has drawn, if it's on screen.
        Task {
            try? await Task.sleep(for: .seconds(1))
            captureSnapshot()
        }
    }

    private func refreshFavicon() async {
        guard let page = webView.url, let host = page.host() else { return }
        let script = """
            (() => { const l = document.querySelector("link[rel~='icon'], link[rel='apple-touch-icon']");
                     return l ? l.href : null; })()
            """
        let declared = (try? await webView.evaluateJavaScript(script)) as? String
        let iconURL = declared.flatMap(URL.init(string:))
            ?? URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL
        let key = iconURL?.absoluteString ?? host
        guard key != faviconHost, let iconURL, ["http", "https", "data"].contains(iconURL.scheme ?? "") else { return }
        faviconHost = key
        // Fetched without the Space's cookies: an icon needs no login.
        if let (data, _) = try? await Self.iconSession.data(from: iconURL), let image = NSImage(data: data) {
            favicon = image
        }
    }

    private static let iconSession = URLSession(configuration: .ephemeral)
}
