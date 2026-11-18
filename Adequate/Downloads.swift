import AppKit
import Foundation
import WebKit

/// One file coming down (or come down) from a page.
@MainActor
final class Download: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let download: WKDownload
    /// The page it came from, for the quarantine record. Nil from a throwaway Space.
    let page: URL?
    let throwaway: Bool
    @Published var name = ""
    /// Where it's being written: known once WebKit asks.
    @Published var file: URL?
    @Published var state = State.running
    @Published var fraction: Double?
    private var observation: NSKeyValueObservation?

    init(_ download: WKDownload, page: URL?, throwaway: Bool) {
        self.download = download
        self.page = page
        self.throwaway = throwaway
        name = download.originalRequest?.url?.lastPathComponent ?? "Download"
        observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let known = progress.totalUnitCount > 0
            let fraction = progress.fractionCompleted
            Task { @MainActor in self?.fraction = known ? fraction : nil }
        }
    }

    func cancel() {
        guard state == .running else { return }
        state = .cancelled
        download.cancel { _ in }
        removePartialFile()
    }

    func removePartialFile() {
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    func reveal() {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// Opened as Finder would: a downloaded app still meets Gatekeeper,
    /// because the file is quarantined.
    func open() {
        guard state == .finished, let file else { return }
        NSWorkspace.shared.open(file)
    }
}

/// Every download this run, newest first. Files go to ~/Downloads, never
/// opened by themselves, and quarantined like Safari's, so whatever's in
/// them gets Gatekeeper's checks when you open it.
@MainActor
final class Downloads: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = Downloads()

    @Published private(set) var items: [Download] = []
    /// Called as each one starts, for a toast.
    var onStart: ((String) -> Void)?

    var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    func track(_ download: WKDownload, from page: URL?, throwaway: Bool) {
        download.delegate = self
        items.insert(Download(download, page: throwaway ? nil : page, throwaway: throwaway), at: 0)
    }

    func remove(_ item: Download) {
        if item.state == .running { item.cancel() }
        items.removeAll { $0 === item }
    }

    /// Clears the finished, failed and cancelled ones; running ones stay.
    func clear() {
        items.removeAll { $0.state != .running }
    }

    func showFolder() {
        NSWorkspace.shared.open(folder)
    }

    private func item(for download: WKDownload) -> Download? {
        items.first { $0.download === download }
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        // Names already given to downloads still starting count as taken,
        // so two at once with the same name don't collide.
        let taken = Set(items.compactMap { $0.state == .running ? $0.file?.path : nil })
        let file = Self.unusedFile(named: Self.safeName(suggestedFilename), in: folder, except: taken)
        if let item = item(for: download) {
            item.name = file.lastPathComponent
            item.file = file
        }
        onStart?(file.lastPathComponent)
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download), let file = item.file else { return }
        item.state = .finished
        item.fraction = 1
        Self.quarantine(file, from: item.download.originalRequest?.url, page: item.page, throwaway: item.throwaway)
        // Bounces the Downloads stack in the Dock, as Safari does.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"),
                                                     object: file.resolvingSymlinksInPath().path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download), item.state == .running else { return }
        item.state = (error as? URLError)?.code == .cancelled ? .cancelled : .failed(error.localizedDescription)
        item.removePartialFile()
    }

    /// A page can't pick where a file goes: no folders, no hidden dotfiles,
    /// nothing Finder would trip over.
    static func safeName(_ suggested: String) -> String {
        var name = (suggested as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "Download" : String(name.prefix(200))
    }

    /// "report.pdf", then "report 2.pdf", "report 3.pdf"…
    static func unusedFile(named name: String, in folder: URL, except taken: Set<String> = []) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) || taken.contains(candidate.path) {
            let numbered = "\(base) \(number)"
            candidate = folder.appendingPathComponent(ext.isEmpty ? numbered : "\(numbered).\(ext)")
            number += 1
        }
        return candidate
    }

    /// Marks the file as downloaded from the web, as Safari does, so opening
    /// an app or script from it goes through Gatekeeper. A throwaway Space's
    /// download carries no addresses, so the record says nothing of where it was.
    static func quarantine(_ file: URL, from source: URL?, page: URL?, throwaway: Bool) {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Adequate",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if !throwaway {
            if let source, ["http", "https"].contains(source.scheme ?? "") {
                properties[kLSQuarantineDataURLKey as String] = source
            }
            if let page { properties[kLSQuarantineOriginURLKey as String] = page }
        }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var file = file
        try? file.setResourceValues(values)
    }
}
