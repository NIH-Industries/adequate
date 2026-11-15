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
    @Published var favicon: NSImage?
    /// Bumped to ask the address bar to take focus.
    @Published var focusRequest = 0
    /// True until something is loaded: only a blank tab starts in the address bar.
    var isBlank = true

    /// Opens a page that asked for a new window as a tab in the same Space.
    /// It must use the given configuration so `window.opener` keeps working.
    var onOpenTab: ((WKWebViewConfiguration) -> WKWebView?)?
    /// Opens a ⌘-clicked link as a background tab in the same Space.
    var onOpenInBackground: ((URL) -> Void)?
    var onClose: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private var faviconHost: String?

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
                MainActor.assumeIsolated { self?.title = webView.title ?? "" }
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

    private static func withoutFragment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    func load(url: URL) {
        isBlank = false
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Opens WebKit's Web Inspector for this tab, through WKWebView's private
    /// inspector object. If a macOS update removes it, this does nothing.
    func showDeveloperTools() {
        guard let inspector = webView.value(forKey: "_inspector") as? NSObject else { return }
        let show = Selector(("show"))
        if inspector.responds(to: show) { inspector.perform(show) }
    }

    func reload() {
        if isLoading { webView.stopLoading() } else { webView.reload() }
    }
    func goBack() { webView.goBack() }
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

    func webViewDidClose(_ webView: WKWebView) {
        // window.close() from a pop-up, e.g. at the end of an OAuth sign-in.
        onClose?()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        // mailto:, zoommtg:, slack: and friends belong to other apps.
        if let scheme = url.scheme, !["http", "https", "file", "about", "data", "blob", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) {
            onOpenInBackground?(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await refreshFavicon() }
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
