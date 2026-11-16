import AppKit
import UserNotifications
import WebKit

/// Web notifications (`new Notification(...)`, Gmail's "desktop
/// notifications") for pages, which WebKit leaves to Safari. A script in
/// each page stands in for the Notification API and hands every request to
/// us: asking is answered per site per Space (and remembered in
/// spaces.json), showing becomes a macOS notification, and clicking one
/// brings back its tab and tells the page, as a browser would.
///
/// They only work while Adequate is open with the tab loaded: no push.
@MainActor
final class PageNotifications: NSObject, WKScriptMessageHandler {
    private static let name = "adequateNotify"
    weak var state: SpaceState?

    static func install(in config: WKWebViewConfiguration, for state: SpaceState) {
        let handler = PageNotifications()
        handler.state = state
        config.userContentController.add(handler, contentWorld: .page, name: name)
    }

    /// The page script, which knows this Space's answers so far.
    static func script(decisions: [String: Bool]) -> WKUserScript {
        let json = (try? JSONEncoder().encode(decisions)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return WKUserScript(source: source.replacingOccurrences(of: "__DECISIONS__", with: json),
                            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              let state, let tab = state.tabs.first(where: { $0.webView === message.webView })
        else { return }
        let site = Self.site(message.frameInfo.securityOrigin)
        switch kind {
        case "ask":
            tab.askToNotify(site: site) { allowed in state.setNotifications(allowed, for: site) }
        case "show":
            guard state.space.notifications?[site] == true, let id = body["id"] as? Int else { return }
            Notifier.shared.show(
                title: body["title"] as? String ?? site, body: body["body"] as? String ?? "",
                tag: body["tag"] as? String ?? "", id: id, site: site, tab: tab, space: state.space)
        case "close":
            if let id = body["id"] as? Int { Notifier.shared.remove(id: id, tab: tab) }
        default:
            break
        }
    }

    static func site(_ origin: WKSecurityOrigin) -> String {
        origin.port == 0 ? origin.host : "\(origin.host):\(origin.port)"
    }

    private static let source = """
        (() => {
          const decisions = __DECISIONS__;
          const site = location.port ? `${location.hostname}:${location.port}` : location.hostname;
          let permission = site in decisions ? (decisions[site] ? 'granted' : 'denied') : 'default';
          const post = message => webkit.messageHandlers.\(name).postMessage(message);
          const live = new Map();
          let next = 1;
          let asking = [];

          class Notification extends EventTarget {
            constructor(title, options = {}) {
              super();
              Object.assign(this, { title: String(title), body: String(options.body ?? ''),
                tag: String(options.tag ?? ''), icon: options.icon ?? '', data: options.data ?? null,
                silent: !!options.silent, requireInteraction: !!options.requireInteraction,
                onclick: null, onclose: null, onshow: null, onerror: null });
              if (permission !== 'granted') { queueMicrotask(() => this._fire('error')); return; }
              this._id = next++;
              live.set(this._id, this);
              post({ kind: 'show', id: this._id, title: this.title, body: this.body, tag: this.tag });
              queueMicrotask(() => this._fire('show'));
            }
            static get permission() { return permission; }
            static get maxActions() { return 0; }
            static requestPermission(callback) {
              return new Promise(resolve => {
                const done = answer => { callback?.(answer); resolve(answer); };
                if (permission !== 'default') return done(permission);
                asking.push(done);
                if (asking.length === 1) post({ kind: 'ask' });
              });
            }
            close() {
              if (!live.delete(this._id)) return;
              post({ kind: 'close', id: this._id });
              this._fire('close');
            }
            _fire(type) {
              const event = new Event(type, { cancelable: true });
              this.dispatchEvent(event);
              this['on' + type]?.call(this, event);
              return event;
            }
          }
          Object.defineProperty(window, 'Notification', { value: Notification, writable: true, configurable: true });

          // Sites that ask the Permissions API, or notify through a service worker.
          const query = navigator.permissions?.query?.bind(navigator.permissions);
          if (query) {
            navigator.permissions.query = descriptor => descriptor?.name === 'notifications'
              ? Promise.resolve(Object.assign(new EventTarget(), { name: 'notifications', onchange: null,
                  state: permission === 'default' ? 'prompt' : permission }))
              : query(descriptor);
          }
          if (window.ServiceWorkerRegistration) {
            ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
              if (permission !== 'granted') return Promise.reject(new TypeError('Notifications are not allowed'));
              new Notification(title, options);
              return Promise.resolve();
            };
          }

          // Answers from Adequate.
          window.__adequateNotify = (kind, value) => {
            if (kind === 'permission') {
              permission = value;
              asking.splice(0).forEach(done => done(value));
            } else if (kind === 'click') {
              const notification = live.get(value);
              // A page that doesn't cancel the click expects its tab brought forward, which Adequate did.
              notification?._fire('click');
            } else if (kind === 'closed') {
              const notification = live.get(value);
              if (notification && live.delete(value)) notification._fire('close');
            }
          };
        })();
        """
}

/// Shows page notifications through macOS, and brings back the tab when one is clicked.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// Finds a tab by id, and shows it: its Space selected, the window forward.
    var reveal: ((UUID) -> Tab?)?
    private var center: UNUserNotificationCenter { .current() }
    private var authorized = false

    /// Set as the delegate before launch finishes, so clicks that launched us are seen.
    func start() { center.delegate = self }

    /// Asks macOS once, the first time a site is allowed.
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    func show(title: String, body: String, tag: String, id: Int, site: String, tab: Tab, space: Space) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = "\(space.symbol) \(space.name) · \(site)"
        content.body = body
        content.sound = .default
        content.threadIdentifier = "\(space.id) \(site)"
        content.userInfo = ["tab": tab.id.uuidString, "id": id]
        // A tag replaces the earlier notification with the same tag, as on the web.
        let identifier = tag.isEmpty ? "\(tab.id) \(id)" : "\(tab.id) tag \(tag)"
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        identifiers["\(tab.id) \(id)"] = identifier
    }

    func remove(id: Int, tab: Tab) {
        guard let identifier = identifiers.removeValue(forKey: "\(tab.id) \(id)") else { return }
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private var identifiers: [String: String] = [:]

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let tabID = (info["tab"] as? String).flatMap(UUID.init(uuidString:))
        let id = info["id"] as? Int
        Task { @MainActor in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
               let tabID, let id, let tab = self.reveal?(tabID) {
                tab.webView.evaluateJavaScript("window.__adequateNotify?.('click', \(id))") { _, _ in }
            }
            completionHandler()
        }
    }
}
