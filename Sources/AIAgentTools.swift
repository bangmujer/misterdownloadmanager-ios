import Foundation

// MARK: - Agent tools for the AI chat tab
//
// When agent mode is on (OpenAI-shape providers only: ChatGPT, Custom,
// Balitech), the chat model can call these tools. Every tool is scoped
// to the app sandbox: the documents folder, the download list, the
// live browser tabs, and plain URL fetches. There is no shell, no
// access outside the sandbox, and no delete tool — removing files
// stays a manual action in My Files.

struct AgentTool {
    let name: String
    let description: String
    let parameters: [String: Any]

    var schema: [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description, "parameters": parameters]]
    }

    static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    static let all: [AgentTool] = [
        AgentTool(
            name: "list_files",
            description: "Lihat isi folder di dalam aplikasi. Folder download ada di path \"Downloads\".",
            parameters: object(["path": string("Subfolder relatif terhadap folder dokumen aplikasi; kosong untuk folder utama.")])
        ),
        AgentTool(
            name: "read_file",
            description: "Baca file teks di dalam folder dokumen aplikasi (maks 64 KB). File biner tidak bisa dibaca.",
            parameters: object(["path": string("Path file relatif terhadap folder dokumen aplikasi, mis. Downloads/catatan.txt.")], required: ["path"])
        ),
        AgentTool(
            name: "write_file",
            description: "Tulis file teks baru atau timpa file teks di dalam folder dokumen aplikasi. Path tidak boleh keluar dari folder aplikasi.",
            parameters: object([
                "path": string("Path file relatif terhadap folder dokumen aplikasi."),
                "content": string("Isi teks file."),
            ], required: ["path", "content"])
        ),
        AgentTool(
            name: "list_downloads",
            description: "Lihat semua download beserta status, progres, dan ukurannya.",
            parameters: object([:])
        ),
        AgentTool(
            name: "manage_download",
            description: "Mulai, jeda, ulangi, atau hapus satu download. remove tidak menghapus file yang sudah selesai.",
            parameters: object([
                "id": string("Nomor urut atau awalan id dari list_downloads."),
                "action": ["type": "string", "enum": ["start", "pause", "retry", "remove"], "description": "Aksi yang dilakukan."],
            ], required: ["id", "action"])
        ),
        AgentTool(
            name: "add_download",
            description: "Tambah download baru dari sebuah URL.",
            parameters: object([
                "url": string("URL file yang mau diunduh."),
                "fileName": string("Nama file yang diinginkan; kosong untuk nama dari URL."),
            ], required: ["url"])
        ),
        AgentTool(
            name: "list_tabs",
            description: "Lihat tab browser yang sedang terbuka beserta judul dan URL-nya.",
            parameters: object([:])
        ),
        AgentTool(
            name: "open_url",
            description: "Buka URL di tab browser baru.",
            parameters: object(["url": string("URL yang mau dibuka.")], required: ["url"])
        ),
        AgentTool(
            name: "get_page_text",
            description: "Baca teks halaman yang sedang terbuka di tab browser aktif (dipotong 6000 karakter).",
            parameters: object([:])
        ),
        AgentTool(
            name: "fetch_url",
            description: "Ambil isi sebuah URL lewat jaringan dan kembalikan sebagai teks (tag HTML dibersihkan, dipotong 8000 karakter).",
            parameters: object(["url": string("URL yang mau diambil isinya.")], required: ["url"])
        ),
        AgentTool(
            name: "app_info",
            description: "Info aplikasi: versi, jumlah download per status, jumlah file, dan jumlah tab browser.",
            parameters: object([:])
        ),
        AgentTool(
            name: "close_tab",
            description: "Tutup satu tab browser. Tab terakhir tidak ditutup, tapi dikembalikan ke halaman awal.",
            parameters: object(["id": string("Nomor urut, awalan id, atau kata kunci judul dari list_tabs.")], required: ["id"])
        ),
        AgentTool(
            name: "switch_tab",
            description: "Pindah ke tab browser lain dan jadikan tab aktif.",
            parameters: object(["id": string("Nomor urut, awalan id, atau kata kunci judul dari list_tabs.")], required: ["id"])
        ),
        AgentTool(
            name: "search_downloads",
            description: "Cari download berdasarkan nama file (tidak peduli huruf besar/kecil).",
            parameters: object(["query": string("Kata kunci nama file; kosong untuk semua download.")], required: ["query"])
        ),
        AgentTool(
            name: "list_bookmarks",
            description: "Lihat bookmark browser yang tersimpan beserta URL-nya.",
            parameters: object([:])
        ),
        AgentTool(
            name: "list_history",
            description: "Lihat 30 entri riwayat browser terbaru beserta judul dan URL-nya.",
            parameters: object([:])
        ),
    ]
}

enum AgentToolRunner {
    static func run(name: String, arguments: [String: Any], store: DownloadStore) async -> String {
        switch name {
        case "list_files":
            return listFiles(path: arguments["path"] as? String ?? "")
        case "read_file":
            return readFile(path: arguments["path"] as? String ?? "")
        case "write_file":
            return writeFile(path: arguments["path"] as? String ?? "", content: arguments["content"] as? String ?? "")
        case "list_downloads":
            return await listDownloads(store: store)
        case "manage_download":
            return await manageDownload(id: arguments["id"] as? String ?? "", action: arguments["action"] as? String ?? "", store: store)
        case "add_download":
            return await addDownload(url: arguments["url"] as? String ?? "", fileName: arguments["fileName"] as? String, store: store)
        case "list_tabs":
            return await listTabs(store: store)
        case "open_url":
            return await openURL(arguments["url"] as? String ?? "", store: store)
        case "get_page_text":
            return await pageText(store: store)
        case "fetch_url":
            return await fetchURL(arguments["url"] as? String ?? "")
        case "app_info":
            return await appInfo(store: store)
        case "close_tab":
            return await closeTab(id: arguments["id"] as? String ?? "", store: store)
        case "switch_tab":
            return await switchTab(id: arguments["id"] as? String ?? "", store: store)
        case "search_downloads":
            return await searchDownloads(query: arguments["query"] as? String ?? "", store: store)
        case "list_bookmarks":
            return await listBookmarks(store: store)
        case "list_history":
            return await listHistory(store: store)
        default:
            return "Perkakas tidak dikenal: \(name)."
        }
    }

    // MARK: - Files (sandboxed to the documents folder)

    private static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Resolves a relative path inside the documents folder, or nil
    /// when it would escape the folder (".." tricks included).
    private static func resolvedPath(_ path: String) -> URL? {
        let base = documentsDir.standardizedFileURL
        let target = (path.isEmpty ? base : base.appendingPathComponent(path)).standardizedFileURL
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else { return nil }
        return target
    }

    private static func listFiles(path: String) -> String {
        guard let dir = resolvedPath(path) else {
            return "Path tidak valid atau keluar dari folder aplikasi."
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return "Folder tidak ditemukan: \(path.isEmpty ? "(utama)" : path)."
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]
        ) else {
            return "Folder tidak bisa dibaca."
        }
        if entries.isEmpty { return "Folder kosong." }
        let lines = entries
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(100)
            .map { url -> String in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true { return url.lastPathComponent + "/" }
                return "\(url.lastPathComponent) (\(formatBytes(Int64(values?.fileSize ?? 0))))"
            }
        return lines.joined(separator: "\n")
    }

    private static func readFile(path: String) -> String {
        guard let file = resolvedPath(path), !path.isEmpty else {
            return "Path tidak valid."
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            return "File tidak ditemukan: \(path)."
        }
        guard let data = try? Data(contentsOf: file) else {
            return "File tidak bisa dibaca: \(path)."
        }
        guard data.count <= 64 * 1024 else {
            return "File terlalu besar (\(formatBytes(Int64(data.count))), maks 64 KB)."
        }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            return "File bukan teks yang bisa dibaca: \(path)."
        }
        return text.isEmpty ? "(File kosong.)" : text
    }

    private static func writeFile(path: String, content: String) -> String {
        guard let file = resolvedPath(path), !path.isEmpty else {
            return "Path tidak valid."
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file, options: .atomic)
            return "Ditulis \(path) (\(content.utf8.count) byte)."
        } catch {
            return "Gagal menulis \(path): \(error.localizedDescription)"
        }
    }

    // MARK: - Tab management (agent tools)

    /// One tab by 1-based number (as list_tabs shows), UUID prefix,
    /// or a word in its title.
    private static func findTab(id: String, in tabs: [BrowserTabState]) -> BrowserTabState? {
        let needle = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(needle), (1...tabs.count).contains(n) { return tabs[n - 1] }
        let lower = needle.lowercased()
        return tabs.first { $0.id.uuidString.lowercased().hasPrefix(lower) }
            ?? tabs.first { $0.displayTitle.lowercased().contains(lower) }
    }

    @MainActor
    private static func closeTab(id: String, store: DownloadStore) -> String {
        guard let session = store.browserSession else {
            return "Browser tidak sedang aktif."
        }
        guard let tab = findTab(id: id, in: session.tabs) else {
            return "Tab tidak ditemukan: \(id). Lihat dulu list_tabs."
        }
        let title = tab.displayTitle.isEmpty ? (tab.urlString.isEmpty ? "tab baru" : tab.urlString) : tab.displayTitle
        session.closeTab(tab.id)
        return "Tab ditutup: \(title)."
    }

    @MainActor
    private static func switchTab(id: String, store: DownloadStore) -> String {
        guard let session = store.browserSession else {
            return "Browser tidak sedang aktif."
        }
        guard let tab = findTab(id: id, in: session.tabs) else {
            return "Tab tidak ditemukan: \(id). Lihat dulu list_tabs."
        }
        session.select(tab.id)
        let index = (session.tabs.firstIndex { $0.id == tab.id } ?? 0) + 1
        let title = tab.displayTitle.isEmpty ? (tab.urlString.isEmpty ? "tab baru" : tab.urlString) : tab.displayTitle
        return "Pindah ke tab \(index): \(title)."
    }

    // MARK: - Downloads

    /// DownloadStore is main-actor-isolated: every helper below
    /// that touches it must be @MainActor itself — calling a
    /// nonisolated helper from a MainActor.run closure does NOT make
    /// its body main-actor-isolated (run #142 failed on exactly this).
    @MainActor
    private static func listDownloads(store: DownloadStore) -> String {
        if store.items.isEmpty { return "Belum ada download." }
        return store.items.enumerated().prefix(30).map { index, item in
            let total = item.totalBytes.map(formatBytes) ?? "?"
            return "\(index + 1). [\(String(item.id.uuidString.prefix(8)))] \(item.fileName) — \(item.state), \(Int(item.progress * 100))%, \(formatBytes(item.downloadedBytes))/\(total) — \(item.url)"
        }.joined(separator: "\n")
    }

    private static func findDownload(id: String, in items: [DownloadItem]) -> DownloadItem? {
        if let n = Int(id), (1...items.count).contains(n) { return items[n - 1] }
        let needle = id.lowercased()
        return items.first { $0.id.uuidString.lowercased().hasPrefix(needle) }
    }

    @MainActor
    private static func manageDownload(id: String, action: String, store: DownloadStore) -> String {
        guard let item = findDownload(id: id, in: store.items) else {
            return "Download tidak ditemukan: \(id). Lihat dulu list_downloads."
        }
        switch action {
        case "start": store.start(id: item.id)
        case "pause": store.pause(id: item.id)
        case "retry": store.retry(id: item.id)
        case "remove": store.remove(id: item.id, deleteFile: false)
        default: return "Aksi tidak dikenal: \(action). Pakai start, pause, retry, atau remove."
        }
        if action == "remove" { return "Download \(item.fileName) dihapus dari daftar (file-nya tetap ada)." }
        let state = store.item(item.id)?.state
        return "\(item.fileName): \(state.map { "\($0)" } ?? action)."
    }

    @MainActor
    private static func addDownload(url: String, fileName: String?, store: DownloadStore) -> String {
        let name = fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = store.addItem(urlString: url, fileName: name?.isEmpty == false ? name : nil) else {
            return "URL tidak valid atau ditolak: \(url)."
        }
        return "Download ditambah: \(item.fileName) [\(String(item.id.uuidString.prefix(8)))]."
    }

    // MARK: - Browser tabs

    @MainActor
    private static func listTabs(store: DownloadStore) -> String {
        guard let session = store.browserSession else {
            return "Browser tidak sedang aktif."
        }
        if session.tabs.isEmpty { return "Tidak ada tab." }
        return session.tabs.enumerated().map { index, tab in
            var line = "\(index + 1). \(tab.displayTitle) — \(tab.urlString.isEmpty ? "(tab baru)" : tab.urlString)"
            if tab.id == session.selectedID { line += " [aktif]" }
            if tab.isIncognito { line += " [incognito]" }
            return line
        }.joined(separator: "\n")
    }

    @MainActor
    private static func openURL(_ urlString: String, store: DownloadStore) -> String {
        guard let session = store.browserSession else {
            return "Browser tidak sedang aktif."
        }
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return "URL tidak valid: \(urlString)."
        }
        session.newTab(url: url)
        return "Dibuka di tab baru: \(urlString)."
    }

    private static func pageText(store: DownloadStore) async -> String {
        let text: String = await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard let session = store.browserSession else {
                    continuation.resume(returning: "")
                    return
                }
                session.extractPageText { text in
                    continuation.resume(returning: text)
                }
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Halaman aktif tidak punya teks yang bisa dibaca." }
        return String(trimmed.prefix(6000))
    }

    // MARK: - Network + info

    private static func fetchURL(_ urlString: String) async -> String {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return "URL tidak valid: \(urlString)."
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                return "HTTP \(status) untuk \(urlString)."
            }
            guard let html = String(data: data.prefix(100 * 1024), encoding: .utf8) else {
                return "Isi URL bukan teks."
            }
            let text = stripHTML(html).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "(Tidak ada teks.)" : String(text.prefix(8000))
        } catch {
            return "Gagal mengambil \(urlString): \(error.localizedDescription)"
        }
    }

    private static func stripHTML(_ html: String) -> String {
        var out = html
        for pattern in ["<script[^>]*>.*?</script>", "<style[^>]*>.*?</style>"] {
            if let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: " ")
            }
        }
        if let re = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: " ")
        }
        out = out
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        return out
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    @MainActor
    private static func appInfo(store: DownloadStore) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var counts: [String: Int] = [:]
        for item in store.items { counts["\(item.state)", default: 0] += 1 }
        let states = counts.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
        let files = (try? FileManager.default.contentsOfDirectory(at: store.downloadsDir, includingPropertiesForKeys: nil))?.count ?? 0
        let tabs = store.browserSession?.tabs.count ?? 0
        return "MDM iOS v\(version). Download: \(store.items.count) total (\(states.isEmpty ? "belum ada" : states)). File di folder Downloads: \(files). Tab browser terbuka: \(tabs)."
    }

    @MainActor
    private static func searchDownloads(query: String, store: DownloadStore) -> String {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = store.items.filter { needle.isEmpty || $0.fileName.lowercased().contains(needle) }
        guard !matches.isEmpty else {
            return "Tidak ada download yang cocok dengan \"\(query)\"."
        }
        return matches.enumerated().prefix(20).map { index, item in
            let total = item.totalBytes.map(formatBytes) ?? "?"
            return "\(index + 1). [\(String(item.id.uuidString.prefix(8)))] \(item.fileName) — \(item.state), \(Int(item.progress * 100))%, \(formatBytes(item.downloadedBytes))/\(total) — \(item.url)"
        }.joined(separator: "\n")
    }

    @MainActor
    private static func listBookmarks(store: DownloadStore) -> String {
        let marks = store.browserSettings.bookmarks
        guard !marks.isEmpty else { return "Belum ada bookmark." }
        return marks.enumerated().map { index, mark in
            "\(index + 1). \(mark.title) — \(mark.urlString)"
        }.joined(separator: "\n")
    }

    @MainActor
    private static func listHistory(store: DownloadStore) -> String {
        let entries = Array(store.browserHistory.prefix(30))
        guard !entries.isEmpty else { return "Riwayat browser kosong." }
        return entries.map { entry in
            "\(entry.title.isEmpty ? entry.urlString : entry.title) — \(entry.urlString)"
        }.joined(separator: "\n")
    }

    private static func formatBytes(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }
}
