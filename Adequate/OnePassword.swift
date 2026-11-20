import AppKit
import WebKit

/// Private but long-standing (Terminal and iTerm use it): a child spawned
/// with this is responsible for itself in macOS's privacy checks.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(_ attributes: UnsafeMutablePointer<posix_spawnattr_t?>,
                                                    _ disclaim: Int32) -> Int32

/// Logins from 1Password, through its command line tool (`op`) and the
/// 1Password app's CLI integration, since a WKWebView app can't load the
/// extension. ⌘⇧P lists the logins saved for the site in the focused frame
/// (only that site and its subdomains, so a lookalike gets nothing), and
/// fills the one you pick. Unlocking is the app's: Touch ID, then a session.
///
/// Secrets never go on a command line or into script source: they come from
/// op's output and go to the page as arguments to a script in WebKit's
/// isolated world, which the page's own scripts can't see or hook.
enum OnePassword {
    struct Login {
        let id: String
        let title: String
        let user: String
        let hosts: [String]
        /// Which 1Password account it's in (its id), and a short name for it.
        let account: String
        let accountName: String
    }

    struct Secrets {
        var username = ""
        var password = ""
        var otp = ""
    }

    struct Failure: Error {
        let message: String
    }

    /// The site the logins were chosen for, which the frame must still be
    /// showing when they're filled.
    struct Site {
        let scheme: String
        let host: String
        let port: String
    }

    /// Where Homebrew and 1Password's installer put it: an app doesn't get your shell's PATH.
    static var tool: URL? {
        ["/opt/homebrew/bin/op", "/usr/local/bin/op"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The list has no secrets in it: titles, usernames and addresses. op
    /// takes many seconds to list a big account, so it's kept until quit and
    /// refreshed behind the scenes once it's a few minutes old.
    @MainActor private static var cached: (at: Date, logins: [Login])?
    @MainActor private static var listing: Task<[Login], Error>?

    /// Whether ⌘⇧P will have to wait for op to list everything.
    @MainActor static var mustWait: Bool { cached == nil }

    @MainActor
    static func logins(for host: String) async throws -> [Login] {
        let all: [Login]
        if let cached {
            all = cached.logins
            if -cached.at.timeIntervalSinceNow > 300 { _ = refresh() }
        } else {
            all = try await refresh().value
        }
        return all.filter { $0.hosts.contains { matches(page: host, saved: $0) } }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// One listing at a time, however many presses ask for it.
    @MainActor
    private static func refresh() -> Task<[Login], Error> {
        if let listing { return listing }
        let task = Task { @MainActor in
            defer { listing = nil }
            let logins = try await everyLogin()
            cached = (Date(), logins)
            return logins
        }
        listing = task
        return task
    }

    /// Every account the 1Password app has (op on its own only searches the
    /// default one), searched side by side. An account that fails (locked,
    /// signed out) is skipped unless they all do.
    private static func everyLogin() async throws -> [Login] {
        let data = try await run(["account", "list", "--format", "json"])
        let accounts = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        guard !accounts.isEmpty else { throw Failure(message: "1Password: no accounts to search") }
        return try await withThrowingTaskGroup(of: Result<[Login], Error>.self) { group in
            for account in accounts {
                guard let id = account["account_uuid"] as? String else { continue }
                let url = account["url"] as? String ?? id
                let name = url.split(separator: ".").first.map(String.init) ?? url
                group.addTask {
                    do {
                        let data = try await run(["item", "list", "--categories", "Login", "--format", "json",
                                                  "--account", id])
                        let items = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
                        return .success(items.compactMap { login($0, account: id, accountName: name) })
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var logins: [Login] = []
            var failure: Error?
            var succeeded = false
            for try await result in group {
                switch result {
                case .success(let found): logins += found; succeeded = true
                case .failure(let error): failure = error
                }
            }
            if !succeeded, let failure { throw failure }
            return logins
        }
    }

    /// Only the three fields a fill needs, not the whole item (notes, security
    /// answers, other passwords). op won't select by label and type at once,
    /// so the one-time code is its own request; an item without one fails it.
    static func secrets(for login: Login) async throws -> Secrets {
        let item = ["item", "get", login.id, "--account", login.account, "--format", "json"]
        async let credentials = run(item + ["--fields", "username,password", "--reveal"])
        async let code = try? run(item + ["--fields", "type=otp"])
        var fields = try fieldList(await credentials)
        if let code = await code { fields += (try? fieldList(code)) ?? [] }
        var secrets = Secrets()
        for field in fields {
            let value = field["value"] as? String ?? ""
            switch (field["purpose"] as? String, field["type"] as? String) {
            case ("USERNAME", _): secrets.username = value
            case ("PASSWORD", _): secrets.password = value
            case (_, "OTP"): secrets.otp = field["totp"] as? String ?? ""
            default: break
            }
        }
        return secrets
    }

    /// op gives one field as an object, several as a list.
    private static func fieldList(_ data: Data) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: data)
        return json as? [[String: Any]] ?? (json as? [String: Any]).map { [$0] } ?? []
    }

    /// The same site, or a subdomain of the saved one (a login saved for
    /// google.com fills on accounts.google.com, not the other way round).
    static func matches(page: String, saved: String) -> Bool {
        let page = bare(page), saved = bare(saved)
        return page == saved || page.hasSuffix("." + saved)
    }

    private static func bare(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func login(_ item: [String: Any], account: String, accountName: String) -> Login? {
        guard let id = item["id"] as? String else { return nil }
        let urls = item["urls"] as? [[String: Any]] ?? []
        let hosts = urls.compactMap { url -> String? in
            guard let href = url["href"] as? String else { return nil }
            return URL(string: href.contains("://") ? href : "https://" + href)?.host()
        }
        guard !hosts.isEmpty else { return nil }
        return Login(id: id, title: item["title"] as? String ?? "Login",
                     user: item["additional_information"] as? String ?? "", hosts: hosts,
                     account: account, accountName: accountName)
    }

    private static func run(_ arguments: [String]) async throws -> Data {
        guard let tool else {
            throw Failure(message: "Install the 1Password CLI (brew install 1password-cli) to fill logins.")
        }
        // Homebrew's folder is yours to write to: make sure it's 1Password's op.
        guard isGenuine(tool) else {
            throw Failure(message: "Not running \(tool.path): it isn't signed by 1Password")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let (status, data, complaint) = try spawn(tool.path, arguments)
                    if status == 0 {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: Failure(message: explain(complaint)))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Signed by 1Password's team, intact. (It could still be swapped between
    /// this check and the launch; the 1Password app checks op too.)
    private nonisolated static func isGenuine(_ tool: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(tool as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(
                  "anchor apple generic and certificate leaf[subject.OU] = \"2BUA8C4S2C\"" as CFString,
                  [], &requirement) == errSecSuccess
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess
    }

    /// Runs op as its own responsible process, as a terminal does. Started
    /// plainly, macOS judges it as Adequate and refuses it 1Password's group
    /// container (where the CLI integration setting lives), and op then
    /// says no accounts are configured.
    private nonisolated static func spawn(_ path: String, _ arguments: [String]) throws -> (Int32, Data, String) {
        let output = Pipe(), errors = Pipe()
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, 2)
        posix_spawn_file_actions_addclose(&actions, output.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, errors.fileHandleForReading.fileDescriptor)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        _ = responsibility_spawnattrs_setdisclaim(&attributes, 1)

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let started = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        guard started == 0 else {
            throw Failure(message: "Couldn't run op: \(String(cString: strerror(started)))")
        }
        // Read stderr alongside, so a chatty op can't fill its pipe and stall.
        var complaint = Data()
        let reading = DispatchGroup()
        DispatchQueue.global().async(group: reading) {
            complaint = errors.fileHandleForReading.readDataToEndOfFile()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        reading.wait()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 1
        return (exitCode, data, String(decoding: complaint, as: UTF8.self))
    }

    /// op's errors, minus its "[ERROR] date time" prefix, with a hint for the usual one.
    private static func explain(_ complaint: String) -> String {
        let line = complaint.split(separator: "\n").first.map(String.init) ?? "op failed"
        let message = line.replacingOccurrences(of: #"^\[ERROR\] \S+ \S+ "#, with: "", options: .regularExpression)
        if message.contains("signed in") || message.contains("sign in") {
            return "1Password: turn on Settings › Developer › Integrate with 1Password CLI"
        }
        return "1Password: \(message)"
    }

    /// Runs in the focused frame's isolated world. Fills a one-time code into
    /// a code field, or the username and password around the focused field.
    /// First it checks the frame is still at the site the login was chosen
    /// for, in the same step as filling, so a page can't swap in between.
    static let fill = """
        if (location.protocol !== `${scheme}:`.toLowerCase()
            || location.hostname.toLowerCase() !== host.toLowerCase()
            || location.port !== port) return 'moved';
        const visible = el => !el.disabled && !el.readOnly && el.getClientRects().length > 0
          && getComputedStyle(el).visibility !== 'hidden';
        const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        const put = (el, value) => {
          el.focus();
          setValue.call(el, value);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        };
        const textual = el => ['text', 'email', 'tel'].includes(el.type);
        const active = document.activeElement instanceof HTMLInputElement ? document.activeElement : null;
        // One-time code fields: said outright, named so, or short and numeric.
        const looksLikeCode = el => el.autocomplete === 'one-time-code'
          || /otp|totp|2fa|mfa|one.?time|verif|token|code/i.test(`${el.name} ${el.id} ${el.placeholder}`)
          || el.inputMode === 'numeric' || el.type === 'number' || (el.maxLength >= 4 && el.maxLength <= 8);
        if (otp && active && active.type !== 'password' && looksLikeCode(active)) {
          put(active, otp);
          return 'otp';
        }
        const inputs = [...(active?.form ?? document).querySelectorAll('input')].filter(visible);
        const passwordField = inputs.find(el => el.type === 'password');
        let userField = inputs.find(el => el.autocomplete === 'username' && textual(el));
        if (!userField && active && textual(active) && !passwordField) userField = active;
        if (!userField) {
          const before = passwordField ? inputs.slice(0, inputs.indexOf(passwordField)) : inputs;
          userField = before.reverse().find(textual);
        }
        if (userField && username) put(userField, username);
        if (passwordField && password) put(passwordField, password);
        return passwordField ? 'login' : userField ? 'username' : 'nothing';
        """

    /// Tells the tab which frame has the field you're in, so filling goes there.
    static let focusScript = WKUserScript(source: """
        addEventListener('focusin', event => {
          if (event.target instanceof HTMLInputElement) webkit.messageHandlers.\(FocusWatch.name).postMessage('focus');
        }, true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)
}

/// Hears which frame last focused a field, in the isolated world.
@MainActor
final class FocusWatch: NSObject, WKScriptMessageHandler {
    nonisolated static let name = "adequateFocus"
    weak var state: SpaceState?

    static func install(in config: WKWebViewConfiguration, for state: SpaceState) {
        let watch = FocusWatch()
        watch.state = state
        config.userContentController.add(watch, contentWorld: .defaultClient, name: name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        state?.tabs.first { $0.webView === message.webView }?.focusedFrame = message.frameInfo
    }
}

extension Tab {
    /// ⌘⇧P: pick a 1Password login for the site in the focused frame and fill it.
    func fillFromOnePassword(toast: @escaping (String) -> Void) {
        let frame = focusedFrame
        let origin = frame?.securityOrigin
        guard let host = origin?.host ?? webView.url?.host(), !host.isEmpty else { return }
        let scheme = origin?.protocol ?? webView.url?.scheme ?? ""
        let port = origin.map { $0.port == 0 ? "" : String($0.port) } ?? webView.url?.port.map(String.init) ?? ""
        // The fill checks the frame still shows this site: it may have moved
        // on since you clicked into it, or while 1Password was busy.
        let site = OnePassword.Site(scheme: scheme, host: host, port: port)
        // Never send a password in the clear (localhost excepted, for development).
        guard scheme == "https" || host == "localhost" || host == "127.0.0.1" else {
            return toast("Not filling: \(host) isn't using HTTPS")
        }
        // Repeat presses while 1Password is still looking are ignored.
        guard !Self.lookingUp else { return }
        if OnePassword.mustWait { toast("Looking in 1Password…") }
        Self.lookingUp = true
        Task {
            defer { Self.lookingUp = false }
            do {
                let logins = try await OnePassword.logins(for: host)
                toast("")
                switch logins.count {
                case 0: toast("No 1Password login for \(host)")
                case 1: fill(logins[0], into: frame, at: site, toast: toast)
                default: choose(from: logins) { self.fill($0, into: frame, at: site, toast: toast) }
                }
            } catch {
                toast((error as? OnePassword.Failure)?.message ?? error.localizedDescription)
            }
        }
    }

    @MainActor private static var lookingUp = false

    /// A menu of logins, drawn by macOS over the page, so the page can't fake it.
    private func choose(from logins: [OnePassword.Login], then: @escaping (OnePassword.Login) -> Void) {
        let menu = NSMenu()
        // Logins from more than one account say which, as 1Password does.
        let several = Set(logins.map(\.account)).count > 1
        for login in logins {
            var title = login.user.isEmpty ? login.title : "\(login.title) — \(login.user)"
            if several { title += "  ·  \(login.accountName)" }
            let item = NSMenuItem(title: title,
                                  action: #selector(MenuChoice.chosen(_:)), keyEquivalent: "")
            let choice = MenuChoice { then(login) }
            item.target = choice
            item.representedObject = choice
            menu.addItem(item)
        }
        let y = webView.isFlipped ? 40 : webView.bounds.height - 40
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: webView.bounds.midX - 120, y: y), in: webView)
    }

    private func fill(_ login: OnePassword.Login, into frame: WKFrameInfo?, at site: OnePassword.Site,
                      toast: @escaping (String) -> Void) {
        Task {
            do {
                let secrets = try await OnePassword.secrets(for: login)
                let result = try await webView.callAsyncJavaScript(
                    OnePassword.fill,
                    arguments: ["username": secrets.username, "password": secrets.password, "otp": secrets.otp,
                                "scheme": site.scheme, "host": site.host, "port": site.port],
                    in: frame, contentWorld: .defaultClient) as? String
                if result == "moved" { return toast("Not filling: the page is no longer \(site.host)") }
                if result == "nothing" { return toast("No login fields to fill here") }
                // The code wasn't filled: it's what the next page will ask for.
                if result != "otp", !secrets.otp.isEmpty {
                    Clipboard.copySecret(secrets.otp)
                    toast("Filled \(login.title) · one-time code copied")
                }
            } catch {
                toast((error as? OnePassword.Failure)?.message ?? "Couldn't fill: \(error.localizedDescription)")
            }
        }
    }
}

/// Holds a menu item's closure: NSMenuItem wants a target object.
private final class MenuChoice: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func chosen(_ sender: Any?) { action() }
}

enum Clipboard {
    /// Copies a one-time code, and clears it a minute later if it's still
    /// there. Marked concealed and transient, which clipboard managers
    /// (nspasteboard.org) skip, and kept off Universal Clipboard.
    @MainActor
    static func copySecret(_ text: String) {
        let board = NSPasteboard.general
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString(text, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let count = board.changeCount
        Task {
            try? await Task.sleep(for: .seconds(60))
            if board.changeCount == count { board.clearContents() }
        }
    }
}
