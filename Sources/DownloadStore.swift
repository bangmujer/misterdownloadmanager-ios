import Combine
import Foundation
import SwiftUI
import UserNotifications
import UIKit

final class ProgressCounter {
    private let lock = NSLock()
    private(set) var total: Int64 = 0
    func add(_ n: Int64) { lock.lock(); total += n; lock.unlock() }
    func reset(to value: Int64) { lock.lock(); total = value; lock.unlock() }
}

@MainActor
final class DownloadStore: ObservableObject {
    @Published var items: [DownloadItem] = []
    @Published var settings = AppSettings()
    @Published var selectedCategory: DownloadCategory = .all
    @Published var searchText = ""
    @Published var pendingClipboardURL: String?
    @Published var remoteAddress: String?
    @Published var lastError: String?
    @Published var browserSettings = BrowserSettings()
    /// Set when a script file is opened from another app (Files share
    /// sheet / Open in), so the UI can confirm the import.
    @Published var lastImportMessage: String?
    @Published var aiHandoff: AIChatHandoff?
    @Published var browserHistory: [BrowserHistoryEntry] = []
    /// Saved website logins (passwords live in the Keychain, metadata in
    /// a JSON file). Changes forward to this store's objectWillChange so
    /// views observing the DownloadStore refresh when logins change.
    let passwords = PasswordStore()
    private var cancellables: Set<AnyCancellable> = []
    @Published var readingList: [ReadingListItem] = []

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var schedulerTimer: Timer?
    private var clipboardTimer: Timer?

    var downloadsDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    var segmentsDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("mdm-segments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var stateURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mdm-state.json")
    }
    private var browserSettingsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mdm-browser-settings.json")
    }
    func saveBrowserSettings() {
        if let data = try? JSONEncoder().encode(browserSettings) {
            try? data.write(to: browserSettingsURL, options: .atomic)
        }
    }
    private func loadBrowserSettings() {
        guard let data = try? Data(contentsOf: browserSettingsURL),
              var decoded = try? JSONDecoder().decode(BrowserSettings.self, from: data) else { return }
        // One-time migration: the old "Desktop site" switch becomes the
        // Safari Mac template; afterwards the preset is the only source.
        if decoded.desktopMode && decoded.userAgentPreset == UserAgentPreset.default.rawValue {
            decoded.userAgentPreset = UserAgentPreset.mac.rawValue
            decoded.desktopMode = false
        }
        browserSettings = decoded
    }

    /// Adds pasted/imported JS source as an extension, honouring the
    /// userscript metadata block (@name, @run-at, @match/@include,
    /// @exclude). Returns the message to show the user.
    @discardableResult
    func importUserscript(source: String, fileName: String) -> String {
        let meta = BrowserExtension.userscriptMeta(source)
        var base = (fileName as NSString).deletingPathExtension
        if base.hasSuffix(".user") { base = String(base.dropLast(5)) }
        let name = meta.name ?? (base.isEmpty ? "Userscript" : base)
        browserSettings.extensions.append(BrowserExtension(name: name, source: source, enabled: true, atDocumentStart: meta.atStart, matches: meta.matches, excludes: meta.excludes))
        saveBrowserSettings()
        var message = "\"\(name)\" diimpor\(meta.atStart ? " (awal dokumen)" : "")"
        if !meta.matches.isEmpty { message += " — hanya: \(meta.matches.joined(separator: ", "))" }
        return message
    }

    /// Imports a script file handed to the app (Files share sheet /
    /// Open in). Copies it into Downloads too, so it also shows up in
    /// My Files. Returns the message to show, or nil when the file is
    /// not a script.
    func importOpenedScriptFile(_ url: URL) -> String? {
        guard ["js", "mjs", "txt"].contains(url.pathExtension.lowercased()) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let source = BrowserExtension.decodeScript(data),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "File kosong atau bukan teks."
        }
        let dest = downloadsDir.appendingPathComponent(url.lastPathComponent)
        if dest != url { try? FileManager.default.copyItem(at: url, to: dest) }
        return importUserscript(source: source, fileName: url.lastPathComponent)
    }

    // MARK: - Browser history

    private var browserHistoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mdm-browser-history.json")
    }
    func saveBrowserHistory() {
        let capped = Array(browserHistory.suffix(500))
        if let data = try? JSONEncoder().encode(capped) {
            try? data.write(to: browserHistoryURL, options: .atomic)
        }
    }
    private func loadBrowserHistory() {
        guard let data = try? Data(contentsOf: browserHistoryURL),
              let decoded = try? JSONDecoder().decode([BrowserHistoryEntry].self, from: data) else { return }
        browserHistory = decoded
    }
    func recordHistory(title: String, urlString: String) {
        if let last = browserHistory.last, last.urlString == urlString { return }
        browserHistory.append(BrowserHistoryEntry(title: title, urlString: urlString))
        if browserHistory.count > 500 { browserHistory.removeFirst(browserHistory.count - 500) }
        saveBrowserHistory()
    }
    func removeHistoryEntry(id: UUID) {
        browserHistory.removeAll { $0.id == id }
        saveBrowserHistory()
    }
    func clearBrowserHistory() {
        browserHistory = []
        saveBrowserHistory()
    }

    // MARK: - Reading list

    private var readingListURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mdm-reading-list.json")
    }
    func saveReadingList() {
        if let data = try? JSONEncoder().encode(readingList) {
            try? data.write(to: readingListURL, options: .atomic)
        }
    }
    private func loadReadingList() {
        guard let data = try? Data(contentsOf: readingListURL),
              let decoded = try? JSONDecoder().decode([ReadingListItem].self, from: data) else { return }
        readingList = decoded
    }
    /// Returns false when the URL is already saved.
    @discardableResult
    func addReadingList(title: String, urlString: String) -> Bool {
        guard !readingList.contains(where: { $0.urlString == urlString }) else { return false }
        readingList.append(ReadingListItem(title: title, urlString: urlString))
        saveReadingList()
        return true
    }
    func removeReadingList(id: UUID) {
        readingList.removeAll { $0.id == id }
        saveReadingList()
    }
    func setReadingListRead(id: UUID, read: Bool) {
        guard let idx = readingList.firstIndex(where: { $0.id == id }) else { return }
        readingList[idx].read = read
        saveReadingList()
    }
    func clearReadItems() {
        readingList.removeAll { $0.read }
        saveReadingList()
    }

    init() {
        passwords.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        load()
        loadBrowserSettings()
        loadBrowserHistory()
        loadReadingList()
        startTimers()
        if settings.autoResumeOnLaunch {
            for item in items where item.state == .downloading || item.state == .queued {
                if item.state == .downloading { updateItem(item.id) { $0.state = .queued } }
            }
            // Resume previously-downloading items only if scheduler allows.
            if schedulerAllowsNow() {
                for item in items where item.state == .queued {
                    // Only auto-resume items that were mid-download (have progress or segments).
                    if item.downloadedBytes > 0 || !item.segments.isEmpty { start(id: item.id) }
                }
            }
        }
        requestNotifications()
    }

    // MARK: - Persistence
    struct SavedState: Codable { var items: [DownloadItem]; var settings: AppSettings }
    func save() {
        let state = SavedState(items: items, settings: settings)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }
    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        items = state.items
        settings = state.settings
        // A relaunch must never show a stale "downloading" state.
        for i in items.indices where items[i].state == .downloading { items[i].state = .paused }
    }

    func updateItem(_ id: UUID, _ mutate: (inout DownloadItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[idx])
        save()
    }
    func item(_ id: UUID) -> DownloadItem? { items.first(where: { $0.id == id }) }

    /// Strips tracking/token junk from a file name derived from a URL.
    /// Some hosts append tokens to the download path itself, e.g.
    /// `kingkongtv-v1.5.apk&k=f5d018...`, which `lastPathComponent`
    /// keeps verbatim (there is no `?` for URL parsing to strip). The
    /// name must end at the file extension: keep the name through the
    /// end of the extension run and drop a following `&...`/`;...`
    /// parameter, plus any `?...`/`#...` leftovers.
    static func cleanFileName(_ raw: String) -> String {
        var name = raw.removingPercentEncoding ?? raw
        if let cut = name.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            name = String(name[..<cut])
        }
        if let dot = name.lastIndex(of: ".") {
            let afterDot = name.index(after: dot)
            if afterDot < name.endIndex {
                let extEnd = name[afterDot...].firstIndex(where: { !$0.isLetter && !$0.isNumber }) ?? name.endIndex
                if extEnd < name.endIndex, name[extEnd] == "&" || name[extEnd] == ";" {
                    name = String(name[..<extEnd])
                }
            }
        } else if let cut = name.firstIndex(where: { $0 == "&" || $0 == ";" }) {
            name = String(name[..<cut])
        }
        name = name.replacingOccurrences(of: "/", with: "_")
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "download" : trimmed
    }

    /// Presigned/CDN URLs (e.g. GitHub release assets served from
    /// objects.githubusercontent.com) carry the real filename only in
    /// the `response-content-disposition` query item; the path itself
    /// is an opaque id. Returns the declared filename, if any.
    static func fileNameFromResponseDispositionQuery(_ url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        for item in items where item.name == "response-content-disposition" {
            if let value = item.value, let name = DownloadEngine.fileNameFromContentDisposition(value) {
                return name
            }
        }
        return nil
    }

    // MARK: - Adding
    @discardableResult
    func addItem(urlString: String, fileName: String? = nil, category: DownloadCategory? = nil, connections: Int? = nil, checksumType: String? = nil, checksumValue: String? = nil, referer: String? = nil, startNow: Bool = true) -> DownloadItem? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" || url.scheme == "ftp" || url.scheme == "magnet" else {
            lastError = "URL tidak valid. Pakai http(s)://, ftp://, atau magnet:."
            return nil
        }
        if trimmed.lowercased().hasPrefix("magnet:") {
            // Magnet links are handled by the torrent flow; keep a placeholder item so the
            // user sees it in the Torrents category instead of silently dropping it.
            var item = DownloadItem(url: trimmed, fileName: fileName ?? "magnet-link.torrent", category: .torrents, state: .paused, isTorrent: true, torrentName: fileName)
            item.errorMessage = "Magnet: tempel di Tambah Torrent untuk mulai mengunduh via peer."
            items.insert(item, at: 0); save(); return item
        }
        let explicitName = fileName?.isEmpty == false ? fileName! : nil
        let rawName = explicitName ?? (url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? "download" : url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
        var name = DownloadStore.cleanFileName(rawName)
        // The server-declared filename in the URL beats a guessed path
        // name (opaque CDN ids), but never a name the user typed.
        if explicitName == nil, let cdName = DownloadStore.fileNameFromResponseDispositionQuery(url) {
            name = DownloadStore.cleanFileName(cdName)
        }
        let cat = category ?? DownloadCategory.from(fileName: name, mime: nil)
        var item = DownloadItem(url: trimmed, fileName: name, category: cat, state: settings.startPaused ? .paused : .queued, connections: connections ?? settings.maxConnections, referer: referer, userAgent: settings.userAgent, checksumType: checksumType, checksumValue: checksumValue, site: url.host)
        item.userAgent = settings.userAgent
        items.insert(item, at: 0)
        save()
        if startNow && !settings.startPaused && schedulerAllowsNow() { start(id: item.id) }
        return item
    }

    func filteredItems() -> [DownloadItem] {
        items.filter { item in
            let catOK = selectedCategory == .all || item.category == selectedCategory
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchOK = q.isEmpty || item.fileName.localizedCaseInsensitiveContains(q) || item.url.localizedCaseInsensitiveContains(q)
            return catOK && searchOK
        }
    }
    func count(for category: DownloadCategory) -> Int {
        category == .all ? items.count : items.filter { $0.category == category }.count
    }

    // MARK: - Control
    func start(id: UUID) {
        guard let item = item(id), item.state != .downloading, item.state != .completed else { return }
        guard activeTasks[id] == nil else { return }
        if activeDownloadsCount() >= settings.maxConcurrentDownloads {
            updateItem(id) { $0.state = .queued; $0.errorMessage = nil }
            return
        }
        updateItem(id) { $0.state = .downloading; $0.errorMessage = nil }
        let task = Task { await self.runDownload(id: id) }
        activeTasks[id] = task
    }
    func pause(id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks[id] = nil
        updateItem(id) { if $0.state == .downloading || $0.state == .queued { $0.state = .paused } }
    }
    func pauseAll() { for item in items where item.state == .downloading { pause(id: item.id) } }
    func startAll() {
        for item in items where item.state == .paused || item.state == .queued { start(id: item.id) }
    }
    func retry(id: UUID) {
        updateItem(id) { $0.state = .queued; $0.errorMessage = nil; $0.downloadedBytes = 0; $0.segments = []; $0.checksumVerified = nil }
        removeSegmentFiles(id: id)
        start(id: id)
    }
    func remove(id: UUID, deleteFile: Bool = false) {
        pause(id: id)
        if deleteFile, let item = item(id) {
            try? FileManager.default.removeItem(at: downloadsDir.appendingPathComponent(item.fileName))
        }
        removeSegmentFiles(id: id)
        items.removeAll { $0.id == id }
        save()
    }
    func activeDownloadsCount() -> Int { items.filter { $0.state == .downloading }.count }

    // MARK: - Cache
    /// Bytes held by temporary download data: segment files plus
    /// `.part` files waiting to resume.
    func downloadCacheSize() -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: nil) {
            for f in files { total += (try? fm.attributesOfItem(atPath: f.path)[.size] as? Int64) ?? 0 }
        }
        if let files = try? fm.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "part" {
                total += (try? fm.attributesOfItem(atPath: f.path)[.size] as? Int64) ?? 0
            }
        }
        return total
    }

    /// Deletes orphaned temp files: `.part` files with no live (not
    /// completed) download of that name, and segment files whose
    /// download id is gone. `.part` files of queued/paused/failed
    /// downloads are kept so they can still resume. Also drops the
    /// shared URL cache. Returns bytes freed.
    @discardableResult
    func clearDownloadCache() -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        let livePartNames = Set(items.filter { $0.state != .completed }.map { $0.fileName + ".part" })
        if let files = try? fm.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "part" && !livePartNames.contains(f.lastPathComponent) {
                freed += (try? fm.attributesOfItem(atPath: f.path)[.size] as? Int64) ?? 0
                try? fm.removeItem(at: f)
            }
        }
        let liveIDs = Set(items.filter { $0.state != .completed }.map { $0.id.uuidString })
        if let files = try? fm.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: nil) {
            for f in files {
                let base = f.lastPathComponent.components(separatedBy: ".seg").first ?? ""
                if !liveIDs.contains(base) {
                    freed += (try? fm.attributesOfItem(atPath: f.path)[.size] as? Int64) ?? 0
                    try? fm.removeItem(at: f)
                }
            }
        }
        URLCache.shared.removeAllCachedResponses()
        return freed
    }

    /// Runs `body` up to 3 times, retrying transient failures: a
    /// connection dropped by the server mid-download must not kill
    /// the whole download. Cancellation is never retried. Static so
    /// segment tasks can use it without capturing the store.
    static func withDownloadRetry(_ body: () async throws -> Void) async throws {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            do {
                try await body()
                return
            } catch {
                if Task.isCancelled { throw error }
                let nsErr = error as NSError
                if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { throw error }
                if attempt >= 3 { throw error }
                try await Task.sleep(nanoseconds: 500_000_000 * UInt64(attempt))
            }
        }
    }

    // MARK: - Engine orchestration
    private func runDownload(id: UUID) async {
        guard var item = item(id) else { return }
        let settingsSnapshot = settings
        let limiter = SpeedLimiter(limitKBps: settingsSnapshot.speedLimitKBps)
        let counter = ProgressCounter()
        counter.reset(to: item.downloadedBytes)

        // Progress ticker: segment callbacks only bump the counter (background-safe);
        // this task publishes to the UI on the main actor.
        let ticker = Task {
            var lastTotal = counter.total
            var lastTime = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let now = Date()
                let total = counter.total
                let dt = now.timeIntervalSince(lastTime)
                let speed = dt > 0 ? Double(total - lastTotal) / dt : 0
                lastTotal = total; lastTime = now
                await MainActor.run {
                    self.updateItem(id) { $0.downloadedBytes = total; $0.speedBytesPerSec = speed }
                }
            }
        }
        defer { ticker.cancel() }

        do {
            let url = URL(string: item.url)!
            // Probe once if we do not know the size yet.
            if item.totalBytes == nil {
                let probe = try await DownloadEngine.probe(url: url, settings: settingsSnapshot, referer: item.referer)
                await MainActor.run {
                    self.updateItem(id) {
                        $0.totalBytes = probe.totalBytes
                        $0.resumeSupported = probe.acceptRanges
                        // Clean the name (tokens like &k=... appended to
                        // the path by some hosts) and prefer the server's
                        // Content-Disposition filename when the URL gave
                        // us nothing usable.
                        $0.fileName = DownloadStore.cleanFileName($0.fileName)
                        if let fn = probe.fileName {
                            let cdName = DownloadStore.cleanFileName(fn)
                            // The server's declared filename wins when the
                            // URL gave us nothing usable (a bare id with
                            // no extension, e.g. a CDN object id) or
                            // nothing at all.
                            let currentExt = ($0.fileName as NSString).pathExtension
                            if $0.fileName == "download" || $0.fileName.isEmpty || currentExt.isEmpty {
                                $0.fileName = cdName
                            }
                        }
                        $0.mimeType = probe.mimeType
                        $0.category = DownloadCategory.from(fileName: $0.fileName, mime: probe.mimeType)
                        $0.url = probe.finalURL.absoluteString
                    }
                }
                item = self.item(id) ?? item
            }
            guard let total = item.totalBytes, item.resumeSupported, total > 1_048_576 else {
                // Single-stream download straight into a .part file (resumable when the server allows it).
                let partURL = downloadsDir.appendingPathComponent(item.fileName + ".part")
                // If we already have the full file, skip straight to finishing.
                // (guard-bound `total` is not in scope inside the guard's else block.)
                if let totalBytes = item.totalBytes {
                    let existing = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? Int64) ?? 0
                    if existing >= totalBytes {
                        try await finishDownload(id: id, partURL: partURL)
                        return
                    }
                }
                // Retry a dropped connection from the on-disk size, so a
                // retry resumes instead of duplicating bytes.
                try await DownloadStore.withDownloadRetry {
                    let existingNow = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? Int64) ?? 0
                    let retryRange: ClosedRange<Int64>? = existingNow > 0 ? existingNow...(item.totalBytes ?? existingNow) : nil
                    _ = try await DownloadEngine.downloadRange(url: url, range: retryRange, destination: partURL, settings: settingsSnapshot, referer: item.referer, limiter: limiter, onBytes: { counter.add($0) })
                }
                try await finishDownload(id: id, partURL: partURL)
                return
            }

            // Segmented download.
            let connections = max(1, min(60, item.connections))
            var segments = item.segments
            if segments.isEmpty {
                let chunk = total / Int64(connections)
                segments = (0..<connections).map { i in
                    let start = Int64(i) * chunk
                    let end = (i == connections - 1) ? total - 1 : start + chunk - 1
                    return SegmentState(start: start, end: end, downloaded: 0, isDone: false, fileName: "\(id.uuidString).seg\(i)")
                }
                await MainActor.run { self.updateItem(id) { $0.segments = segments } }
            }
            // Refresh each segment's downloaded count from its on-disk file.
            for i in segments.indices {
                let segURL = segmentsDir.appendingPathComponent(segments[i].fileName)
                let size = (try? FileManager.default.attributesOfItem(atPath: segURL.path)[.size] as? Int64) ?? 0
                segments[i].downloaded = min(size, segments[i].end - segments[i].start + 1)
                segments[i].isDone = segments[i].downloaded >= (segments[i].end - segments[i].start + 1)
            }
            await MainActor.run { self.updateItem(id) { $0.segments = segments } }

            let segDir = segmentsDir
            let downloadURL = url
            let refererValue = item.referer
            try await withThrowingTaskGroup(of: Void.self) { group in
                for seg in segments where !seg.isDone {
                    group.addTask {
                        let segURL = segDir.appendingPathComponent(seg.fileName)
                        // A segment whose connection drops is retried from
                        // its on-disk size instead of failing the download.
                        try await DownloadStore.withDownloadRetry {
                            let size = (try? FileManager.default.attributesOfItem(atPath: segURL.path)[.size] as? Int64) ?? 0
                            let from = seg.start + min(size, seg.end - seg.start + 1)
                            guard from <= seg.end else { return }
                            _ = try await DownloadEngine.downloadRange(url: downloadURL, range: from...seg.end, destination: segURL, settings: settingsSnapshot, referer: refererValue, limiter: limiter, onBytes: { counter.add($0) })
                        }
                    }
                }
                try await group.waitForAll()
            }
            // Merge segments in order.
            let partURL = downloadsDir.appendingPathComponent(item.fileName + ".part")
            if FileManager.default.fileExists(atPath: partURL.path) { try? FileManager.default.removeItem(at: partURL) }
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            let outHandle = try FileHandle(forWritingTo: partURL)
            for seg in segments {
                let segURL = segmentsDir.appendingPathComponent(seg.fileName)
                let inHandle = try FileHandle(forReadingFrom: segURL)
                while true {
                    let chunk = try inHandle.read(upToCount: 1_048_576) ?? Data()
                    if chunk.isEmpty { break }
                    try outHandle.write(contentsOf: chunk)
                }
                try inHandle.close()
            }
            try outHandle.close()
            removeSegmentFiles(id: id)
            try await finishDownload(id: id, partURL: partURL)
        } catch is CancellationError {
            await MainActor.run { self.updateItem(id) { if $0.state == .downloading { $0.state = .paused } } }
        } catch {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                await MainActor.run { self.updateItem(id) { if $0.state == .downloading { $0.state = .paused } } }
            } else {
                await MainActor.run {
                    self.updateItem(id) { $0.state = .failed; $0.errorMessage = error.localizedDescription; $0.speedBytesPerSec = 0 }
                }
                notify(title: "Download gagal", body: item.fileName)
            }
        }
        await MainActor.run { self.activeTasks[id] = nil }
    }

    private func finishDownload(id: UUID, partURL: URL) async throws {
        guard let item = item(id) else { return }
        let finalURL = downloadsDir.appendingPathComponent(item.fileName)
        // Avoid overwriting an existing file silently: add (1), (2), ...
        var dest = finalURL
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) && dest != partURL {
            let base = (item.fileName as NSString).deletingPathExtension
            let ext = (item.fileName as NSString).pathExtension
            dest = downloadsDir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        if FileManager.default.fileExists(atPath: partURL.path) {
            if dest.path != partURL.path { try FileManager.default.moveItem(at: partURL, to: dest) }
        }
        var verified: Bool?
        if let type = item.checksumType, let expected = item.checksumValue, !expected.isEmpty {
            await MainActor.run { self.updateItem(id) { $0.state = .verifying } }
            verified = try DownloadEngine.verifyChecksum(file: dest, type: type, expected: expected)
        }
        await MainActor.run {
            self.updateItem(id) {
                $0.state = .completed
                $0.completedAt = Date()
                $0.speedBytesPerSec = 0
                $0.downloadedBytes = $0.totalBytes ?? $0.downloadedBytes
                $0.checksumVerified = verified
                $0.fileName = dest.lastPathComponent
            }
        }
        notify(title: "Download selesai", body: item.fileName)
    }

    private func removeSegmentFiles(id: UUID) {
        let prefix = id.uuidString
        if let files = try? FileManager.default.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: f) }
        }
    }

    // MARK: - Scheduler / timers
    func schedulerAllowsNow() -> Bool {
        guard settings.schedulerEnabled else { return true }
        let cal = Calendar.current
        let now = Date()
        let nowMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let start = settings.schedulerStartHour * 60 + settings.schedulerStartMinute
        let stop = settings.schedulerStopHour * 60 + settings.schedulerStopMinute
        if start == stop { return true }
        if start < stop { return nowMin >= start && nowMin < stop }
        return nowMin >= start || nowMin < stop // overnight window
    }

    private func startTimers() {
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.settings.schedulerEnabled {
                    if !self.schedulerAllowsNow() { self.pauseAll() }
                    else if self.settings.queueEnabled {
                        for item in self.items where item.state == .queued { self.start(id: item.id) }
                    }
                }
            }
        }
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.checkClipboard() }
        }
    }

    func checkClipboard() {
        guard settings.clipboardMonitor else { return }
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("http"), URL(string: text) != nil,
              !items.contains(where: { $0.url == text }) else { return }
        if pendingClipboardURL != text { pendingClipboardURL = text }
    }

    // MARK: - Notifications
    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    func notify(title: String, body: String) {
        guard settings.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Files on disk
    func downloadedFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    }
    func deleteDownloadedFile(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
