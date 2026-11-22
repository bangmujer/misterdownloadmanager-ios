import Foundation
import ZIPFoundation
import Network

/// Archive extraction: ZIP via ZIPFoundation (stored + deflate). 7z/RAR need
/// the external 7-Zip program on desktop; on iOS there is no such helper, so
/// those formats report as unsupported instead of pretending to extract.
enum ArchiveExtractor {
    static func isSupportedArchive(_ fileName: String) -> Bool {
        ["zip"].contains((fileName as NSString).pathExtension.lowercased())
    }
    static func extract(zipURL: URL, to destinationDir: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let archive = try Archive(url: zipURL, accessMode: .read)
        var extracted: [URL] = []
        for entry in archive {
            let dest = destinationDir.appendingPathComponent(entry.path)
            if entry.type == .directory {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: dest)
                extracted.append(dest)
            }
        }
        return extracted
    }
}

/// Minimal LAN remote control, mirroring MDM's mdm-remote idea: while the app
/// is in the foreground, a paired phone/browser on the same Wi-Fi can list
/// downloads and add/pause/resume them over plain HTTP on the chosen port.
/// No authentication in v1 — keep it on trusted home Wi-Fi only; the settings
/// screen says so. The desktop remote uses HTTPS pairing; iOS cannot mint
/// the same pairing flow without a shared identity, so this is HTTP-only.
final class RemoteServer {
    private var listener: NWListener?
    private weak var store: DownloadStore?

    func start(store: DownloadStore, port: UInt16) {
        self.store = store
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            Task { @MainActor in store.lastError = "Remote control gagal start: \(error.localizedDescription)" }
            return
        }
        listener?.stateUpdateHandler = { state in
            if case .ready = state {
                let address = "http://\(Self.localIPAddress() ?? "localhost"):\(port)/"
                Task { @MainActor in store.remoteAddress = address }
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel(); listener = nil
        Task { @MainActor in self.store?.remoteAddress = nil }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            defer { connection.cancel() }
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { return }
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.components(separatedBy: " ")
            let path = parts.count > 1 ? parts[1] : "/"
            let body = self.responseBody(for: path)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            _ = isComplete; _ = error
        }
    }

    private func responseBody(for path: String) -> String {
        guard let store = store else { return "<h1>MDM iOS</h1>" }
        // Actions are read synchronously from the store's published state on the
        // main actor via a quick hop; mutations go through Task so the HTTP
        // reply is never blocked on the UI thread.
        if path.hasPrefix("/add") {
            if let comps = URLComponents(string: "http://x\(path)"), let url = comps.queryItems?.first(where: { $0.name == "url" })?.value {
                Task { @MainActor in _ = store.addItem(urlString: url) }
                return "<h1>Added</h1><p>\(url)</p><a href='/'>Back</a>"
            }
        }
        if path.hasPrefix("/pause/") {
            let idStr = String(path.dropFirst("/pause/".count))
            if let id = UUID(uuidString: idStr) { Task { @MainActor in store.pause(id: id) } }
        }
        if path.hasPrefix("/resume/") {
            let idStr = String(path.dropFirst("/resume/".count))
            if let id = UUID(uuidString: idStr) { Task { @MainActor in store.start(id: id) } }
        }
        // Snapshot read must happen on the main actor; the listener thread
        // cannot safely read @Published state, so render from a cached copy
        // refreshed by the store (see RemoteSnapshot below).
        let rows = RemoteSnapshot.shared.rows.map { row in
            "<li>\(row.name) — \(row.state) \(Int(row.progress * 100))% — <a href='/pause/\(row.id)'>Pause</a> <a href='/resume/\(row.id)'>Resume</a></li>"
        }.joined()
        return "<html><head><meta name='viewport' content='width=device-width'></head><body><h1>Mister Download Manager (iOS)</h1><p>Remote control — trusted Wi-Fi only.</p><form action='/add'><input name='url' placeholder='https://…' size='40'><button>Add</button></form><ul>\(rows)</ul></body></html>"
    }

    static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            if (flags & Int32(IFF_UP)) != 0, (flags & Int32(IFF_LOOPBACK)) == 0 {
                let addr = ptr.pointee.ifa_addr.pointee
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let name = String(cString: hostname)
                        if !name.hasPrefix("127.") { address = name; break }
                    }
                }
            }
        }
        return address
    }
}

/// Small locked snapshot so the background HTTP listener never touches
/// @Published state off the main thread.
final class RemoteSnapshot {
    static let shared = RemoteSnapshot()
    struct Row { var id: UUID; var name: String; var state: String; var progress: Double }
    private let lock = NSLock()
    private var _rows: [Row] = []
    var rows: [Row] { lock.lock(); defer { lock.unlock() }; return _rows }
    func refresh(from items: [DownloadItem]) {
        let newRows = items.map { Row(id: $0.id, name: $0.fileName, state: $0.state.label, progress: $0.progress) }
        lock.lock(); _rows = newRows; lock.unlock()
    }
}
