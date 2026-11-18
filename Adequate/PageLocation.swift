import CoreLocation
import WebKit

/// Where you are (navigator.geolocation) for pages. A WKWebView on macOS
/// has no location source of its own (Safari brings its own), so it asks
/// and then never gets a fix. A script in every frame stands in for
/// navigator.geolocation and hands each request to us: the site is asked
/// about once per Space like the camera, and positions come from
/// CoreLocation, which asks macOS once whether Adequate may use it.
@MainActor
final class PageLocation: NSObject, WKScriptMessageHandler {
    private static let name = "adequateLocation"
    weak var state: SpaceState?

    static func install(in config: WKWebViewConfiguration, for state: SpaceState) {
        let handler = PageLocation()
        handler.state = state
        config.userContentController.add(handler, contentWorld: .page, name: name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              let id = body["id"] as? Int, let token = body["frame"] as? String,
              let tab = state?.tabs.first(where: { $0.webView === message.webView })
        else { return }
        let frame = message.frameInfo
        let request = Locator.Request(webView: tab.webView, frame: frame, token: token, id: id)
        switch kind {
        case "get", "watch":
            tab.askForLocation(site: PageNotifications.site(frame.securityOrigin)) { allowed in
                guard allowed else { return request.fail(code: 1, "User denied Geolocation") }
                Locator.shared.add(request, watching: kind == "watch")
            }
        case "clear":
            Locator.shared.remove(request)
        default:
            break
        }
    }

    /// Every frame, so embedded maps work too; only where the page already
    /// has navigator.geolocation (secure pages), so insecure ones still don't.
    static let script = WKUserScript(source: source, injectionTime: .atDocumentStart,
                                     forMainFrameOnly: false, in: .page)

    private static let source = """
        (() => {
          if (!navigator.geolocation || !window.webkit?.messageHandlers?.\(name)) return;
          // Names this frame, so its ids don't mix with other frames'.
          const frame = Math.random().toString(36).slice(2);
          const post = message => webkit.messageHandlers.\(name).postMessage({ ...message, frame });
          const pending = new Map();
          let next = 1;
          let granted = false;

          const error = (code, message) => ({ code, message,
            PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });

          const request = (kind, success, failure, options = {}) => {
            const id = next++;
            const entry = { success, failure, watch: kind === 'watch', timer: null };
            const timeout = options?.timeout;
            if (Number.isFinite(timeout) && timeout >= 0 && kind === 'get') {
              entry.timer = setTimeout(() => {
                if (!pending.delete(id)) return;
                post({ kind: 'clear', id });
                failure?.(error(3, 'Timeout expired'));
              }, timeout);
            }
            pending.set(id, entry);
            post({ kind, id });
            return id;
          };

          const geolocation = navigator.geolocation;
          Object.defineProperties(geolocation, {
            getCurrentPosition: { configurable: true, writable: true,
              value: (success, failure, options) => { request('get', success, failure, options); } },
            watchPosition: { configurable: true, writable: true,
              value: (success, failure, options) => request('watch', success, failure, options) },
            clearWatch: { configurable: true, writable: true,
              value: id => { if (pending.delete(id)) post({ kind: 'clear', id }); } },
          });

          // Sites that check the Permissions API before asking.
          const query = navigator.permissions?.query?.bind(navigator.permissions);
          if (query) {
            navigator.permissions.query = descriptor => descriptor?.name === 'geolocation' && granted
              ? Promise.resolve(Object.assign(new EventTarget(), { name: 'geolocation', onchange: null, state: 'granted' }))
              : query(descriptor);
          }

          // Answers from Adequate.
          window.__adequateLocation = (id, position, code, message) => {
            const entry = pending.get(id);
            if (!entry) return;
            if (!entry.watch || code) pending.delete(id);
            clearTimeout(entry.timer);
            entry.timer = null;
            if (code) return entry.failure?.(error(code, message));
            granted = true;
            const coords = position.coords;
            entry.success?.({ coords: { ...coords, toJSON() { return coords; } },
                              timestamp: position.timestamp,
                              toJSON() { return position; } });
          };
        })();
        """
}

/// The one CoreLocation client: runs while any page wants a position, and
/// stops when none do.
@MainActor
final class Locator: NSObject, CLLocationManagerDelegate {
    static let shared = Locator()

    @MainActor
    struct Request {
        weak var webView: WKWebView?
        let frame: WKFrameInfo
        let token: String
        let id: Int

        func same(as other: Request) -> Bool {
            webView === other.webView && token == other.token && id == other.id
        }

        func send(_ arguments: String) {
            webView?.evaluateJavaScript("window.__adequateLocation?.(\(id), \(arguments))",
                                        in: frame, in: .page) { _ in }
        }

        func fail(code: Int, _ message: String) {
            send("null, \(code), \(Self.quoted(message))")
        }

        private static func quoted(_ text: String) -> String {
            (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "''"
        }
    }

    private let manager = CLLocationManager()
    private var once: [Request] = []
    private var watching: [Request] = []
    private var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func add(_ request: Request, watching watch: Bool) {
        // A recent fix answers a one-off straight away.
        if !watch, let last = manager.location, -last.timestamp.timeIntervalSinceNow < 30 {
            return request.send(Self.json(last))
        }
        if watch {
            watching.append(request)
            if let last = manager.location { request.send(Self.json(last)) }
        } else {
            once.append(request)
        }
        update()
    }

    func remove(_ request: Request) {
        once.removeAll { $0.same(as: request) }
        watching.removeAll { $0.same(as: request) }
        update()
    }

    /// The tab went to another page (or closed): its requests went with it.
    func forget(_ webView: WKWebView) {
        once.removeAll { $0.webView == nil || $0.webView === webView }
        watching.removeAll { $0.webView == nil || $0.webView === webView }
        update()
    }

    private func update() {
        let wanted = !once.isEmpty || !watching.isEmpty
        guard wanted != running else { return }
        running = wanted
        if wanted {
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .denied, .restricted: return failAll(code: 1, "Adequate isn't allowed to use Location Services")
            default: break
            }
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
    }

    private func failAll(code: Int, _ message: String) {
        (once + watching).forEach { $0.fail(code: code, message) }
        once = []
        watching = []
        running = false
        manager.stopUpdatingLocation()
    }

    private static func json(_ location: CLLocation) -> String {
        var coords: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "altitude": NSNull(), "altitudeAccuracy": NSNull(), "heading": NSNull(), "speed": NSNull(),
        ]
        if location.verticalAccuracy > 0 {
            coords["altitude"] = location.altitude
            coords["altitudeAccuracy"] = location.verticalAccuracy
        }
        if location.course >= 0 { coords["heading"] = location.course }
        if location.speed >= 0 { coords["speed"] = location.speed }
        let position: [String: Any] = ["coords": coords,
                                       "timestamp": (location.timestamp.timeIntervalSince1970 * 1000).rounded()]
        let data = (try? JSONSerialization.data(withJSONObject: position)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated {
            let position = Self.json(location)
            once.forEach { $0.send(position) }
            once = []
            watching.removeAll { $0.webView == nil }
            watching.forEach { $0.send(position) }
            update()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        MainActor.assumeIsolated {
            switch code {
            case .denied: failAll(code: 1, "Adequate isn't allowed to use Location Services")
            // Still looking: CoreLocation keeps trying, so keep waiting.
            case .locationUnknown: break
            default: failAll(code: 2, "Position unavailable")
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            if status == .denied || status == .restricted, running {
                failAll(code: 1, "Adequate isn't allowed to use Location Services")
            }
        }
    }
}
