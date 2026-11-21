import Foundation

/// The sites visited in one Space, for suggestions in the address bar. Kept
/// in its own file per Space, never shared between them. A site is just its
/// protocol and domain: Gmail and Slack make an address for every message,
/// and one entry each is what you want back.
@MainActor
final class History {
    struct Entry: Codable {
        var url: String
        var title: String
        var visits: Int
        /// Visits that started in the address bar, which say more about what you want back.
        var typed: Int
        var last: Date
    }

    private static let folder = SpaceStore.file.deletingLastPathComponent().appendingPathComponent("history")
    private static let limit = 3000
    /// nil for a throwaway Space: suggestions last until Adequate quits, and nothing is written.
    private let file: URL?
    private var entries: [String: Entry] = [:]
    private var saveTask: Task<Void, Never>?

    init(space: UUID, persistent: Bool = true) {
        file = persistent ? Self.folder.appendingPathComponent("\(space.uuidString).json") : nil
        if let file, let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            // Older files kept whole addresses: fold those into their sites.
            var merged: [String: (entry: Entry, best: Int)] = [:]
            for entry in list {
                guard let key = URL(string: entry.url).flatMap(Self.key) else { continue }
                guard var site = merged[key] else {
                    merged[key] = (Entry(url: key, title: entry.title, visits: entry.visits,
                                         typed: entry.typed, last: entry.last), entry.visits)
                    continue
                }
                site.entry.visits += entry.visits
                site.entry.typed += entry.typed
                site.entry.last = max(site.entry.last, entry.last)
                // The title of its most visited page names the site best.
                if entry.visits > site.best, !entry.title.isEmpty { (site.entry.title, site.best) = (entry.title, entry.visits) }
                merged[key] = site
            }
            entries = merged.mapValues(\.entry)
            if entries.count != list.count { saveSoon() }
        }
    }

    static func erase(space: UUID) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(space.uuidString).json"))
    }

    /// A page finished loading: a visit to its site.
    func record(_ url: URL, title: String, typed: Bool) {
        guard let key = Self.key(url) else { return }
        var entry = entries[key] ?? Entry(url: key, title: "", visits: 0, typed: 0, last: .now)
        entry.visits += 1
        if typed { entry.typed += 1 }
        if !title.isEmpty { entry.title = title }
        entry.last = .now
        entries[key] = entry
        saveSoon()
    }

    /// The title often arrives after the page has finished.
    func retitle(_ url: URL, _ title: String) {
        guard !title.isEmpty, let key = Self.key(url), entries[key] != nil, entries[key]?.title != title else { return }
        entries[key]?.title = title
        saveSoon()
    }

    struct Suggestion: Identifiable {
        let entry: Entry
        /// What you typed is the start of its address, so Return can go straight there.
        let isPrefix: Bool
        var id: String { entry.url }
    }

    func suggestions(for text: String, limit: Int = 6) -> [Suggestion] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        let stripped = Self.bare(query)
        let words = query.split(separator: " ").map(String.init)
        let now = Date.now
        return entries.values.compactMap { entry -> (Suggestion, Double)? in
            let address = Self.bare(entry.url.lowercased())
            let isPrefix = !stripped.isEmpty && address.hasPrefix(stripped)
            // Addresses only: titles aren't shown, and a site's last title is
            // often a passing one ("Redirecting…"), so they'd match for no visible reason.
            guard isPrefix || words.allSatisfy(address.contains) else { return nil }
            // Visits, typed ones worth more, fading with a two-week half-life.
            let age = now.timeIntervalSince(entry.last) / 86_400
            var score = Double(entry.visits + 3 * entry.typed) * pow(0.5, age / 14)
            // The shorter of two prefix matches is likely the site itself.
            if isPrefix { score = score * 4 + 1 / Double(address.count) }
            return (Suggestion(entry: entry, isPrefix: isPrefix), score)
        }
        .sorted { ($0.0.isPrefix ? 1 : 0, $0.1) > ($1.0.isPrefix ? 1 : 0, $1.1) }
        .prefix(limit)
        .map(\.0)
    }

    /// A site as you'd type it to carry on to a page there: bare, with a
    /// slash to add a path after. A plain-HTTP site keeps its http://, or
    /// it'd be taken for HTTPS.
    static func editable(_ url: String) -> String {
        let address = url.hasPrefix("http://") && !bare(url).hasPrefix("localhost") ? url : bare(url)
        return address + "/"
    }

    /// An address without its scheme or www., as you'd type it.
    static func bare(_ address: String) -> String {
        var text = address
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text
    }

    /// Whether any page on this host (www. or not) has been visited here.
    func hasVisited(host: String) -> Bool {
        let wanted = Self.bare(host.lowercased())
        return entries.keys.contains { URL(string: $0)?.host().map { Self.bare($0) } == wanted }
    }

    /// The site: protocol, domain and any port, e.g. https://mail.google.com.
    private static func key(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    private func saveSoon() {
        guard file != nil else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        // Over the limit, the least visited and longest unvisited go first.
        var list = Array(entries.values)
        if list.count > Self.limit {
            list.sort { ($0.visits + 3 * $0.typed, $0.last) > ($1.visits + 3 * $1.typed, $1.last) }
            list = Array(list.prefix(Self.limit))
            entries = Dictionary(list.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        }
        guard let file, let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
