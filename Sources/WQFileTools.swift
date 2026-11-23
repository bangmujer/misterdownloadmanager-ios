import Foundation
import CryptoKit
import SQLite3

// MARK: - WQFiles-style file tools, scoped to this app's own sandbox
//
// WQFiles (kolbicz/WQFiles, GPL-3.0) is a file browser built on the
// `worse_query` sandbox technique: it opens OTHER apps' and system containers
// on iOS 26–27.3 beta 1, and Apple patched that technique in 27.3 beta 2.
// That cross-app access cannot be ported here: this app targets iOS 16+ and
// installs via TrollStore, so it can only ever see its own container.
// Everything in this file is therefore the portable part of WQFiles — its
// Files-tool behaviour (browse, info, search, largest files, favorites,
// backups-before-delete, plist/hex/SQLite/text viewers) — reimplemented in
// Swift against the app's own sandbox. No sandbox escape is attempted.

enum WQSort: String, CaseIterable {
    case name, dateModified, dateCreated, size
    var label: String {
        switch self {
        case .name: return "Nama"
        case .dateModified: return "Tanggal diubah"
        case .dateCreated: return "Tanggal dibuat"
        case .size: return "Ukuran"
        }
    }
}

func wqSortContents(_ urls: [URL], by sort: WQSort, ascending: Bool) -> [URL] {
    let fm = FileManager.default
    func sizeOf(_ u: URL) -> Int64 {
        (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
    }
    func dateOf(_ u: URL, key: FileAttributeKey) -> Date {
        (try? fm.attributesOfItem(atPath: u.path)[key] as? Date) ?? .distantPast
    }
    let sorted: [URL]
    switch sort {
    case .name:
        sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    case .dateModified:
        sorted = urls.sorted { dateOf($0, key: .modificationDate) < dateOf($1, key: .modificationDate) }
    case .dateCreated:
        sorted = urls.sorted { dateOf($0, key: .creationDate) < dateOf($1, key: .creationDate) }
    case .size:
        sorted = urls.sorted { sizeOf($0) < sizeOf($1) }
    }
    return ascending ? sorted : sorted.reversed()
}

func wqIsDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
}

func wqFileSize(_ url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
}

func wqSHA256(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func wqFolderSize(_ url: URL) async -> Int64 {
    var total: Int64 = 0
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return 0 }
    for case let file as URL in enumerator {
        if Task.isCancelled { break }
        total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
    return total
}

func wqSearch(in root: URL, matching query: String, limit: Int = 500) async -> [URL] {
    var hits: [URL] = []
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
    for case let file as URL in enumerator {
        if Task.isCancelled || hits.count >= limit { break }
        if file.lastPathComponent.localizedCaseInsensitiveContains(query) { hits.append(file) }
    }
    return hits
}

func wqLargestFiles(in root: URL, limit: Int = 100) async -> [(url: URL, size: Int64)] {
    var all: [(URL, Int64)] = []
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
    for case let file as URL in enumerator {
        if Task.isCancelled { break }
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { continue }
        all.append((file, Int64(values?.fileSize ?? 0)))
    }
    return all.sorted { $0.1 > $1.1 }.prefix(limit).map { $0 }
}

// MARK: - Favorites (persisted paths inside the sandbox)

enum WQFavorites {
    private static let key = "mdm-wq-favorites-v1"
    static func all() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func contains(_ url: URL) -> Bool { all().contains(url) }
    static func toggle(_ url: URL) {
        var paths = all().map { $0.path }
        if let i = paths.firstIndex(of: url.path) { paths.remove(at: i) } else { paths.append(url.path) }
        UserDefaults.standard.set(paths, forKey: key)
    }
}

// MARK: - Backups before delete / overwrite (WQFiles safety model)

enum WQBackups {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("mdm-backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    struct Entry: Identifiable, Hashable {
        let id: String
        let backupURL: URL
        let originalPath: String
        let date: Date
        var originalExists: Bool { FileManager.default.fileExists(atPath: originalPath) }
        var displayName: String { URL(fileURLWithPath: originalPath).lastPathComponent }
    }

    /// Copies `url` into Backups and returns the backup folder. Refuses to
    /// back up anything already inside the backups dir (no recursive backups).
    @discardableResult
    static func backup(_ url: URL) -> URL? {
        if url.path.hasPrefix(dir.path) { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = dir.appendingPathComponent("\(stamp)_\(url.lastPathComponent)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
            try url.path.write(to: folder.appendingPathComponent(".wq-original-path"), atomically: true, encoding: .utf8)
            return folder
        } catch { return nil }
    }

    static func entries() -> [Entry] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { folder in
            guard let pathData = try? Data(contentsOf: folder.appendingPathComponent(".wq-original-path")),
                  let original = String(data: pathData, encoding: .utf8) else { return nil }
            let date = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return Entry(id: folder.lastPathComponent, backupURL: folder, originalPath: original, date: date)
        }.sorted { $0.date > $1.date }
    }

    /// Recently Deleted: backups whose original is gone.
    static func recentlyDeleted() -> [Entry] { entries().filter { !$0.originalExists } }

    static func restore(_ entry: Entry) -> Bool {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: entry.backupURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard let item = contents.first(where: { $0.lastPathComponent != ".wq-original-path" }) else { return false }
        let dest = URL(fileURLWithPath: entry.originalPath)
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: item, to: dest)
            try fm.removeItem(at: entry.backupURL)
            return true
        } catch { return false }
    }

    static func deleteBackup(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.backupURL)
    }
}

// MARK: - Plist model (edit preserving binary/XML format)

indirect enum WQPlistValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case array([WQPlistValue])
    case dict([(key: String, value: WQPlistValue)])

    var typeLabel: String {
        switch self {
        case .string: return "String"
        case .int: return "Integer"
        case .double: return "Real"
        case .bool: return "Boolean"
        case .date: return "Date"
        case .data: return "Data"
        case .array: return "Array"
        case .dict: return "Dictionary"
        }
    }

    static func from(_ any: Any) -> WQPlistValue {
        switch any {
        case let v as String: return .string(v)
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(v)
        case let v as Double: return .double(v)
        case let v as Float: return .double(Double(v))
        case let v as Date: return .date(v)
        case let v as Data: return .data(v)
        case let v as [Any]: return .array(v.map(from))
        case let v as [String: Any]: return .dict(v.keys.sorted().map { ($0, from(v[$0]!)) })
        default: return .string("\(any)")
        }
    }

    func toAny() -> Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .date(let v): return v
        case .data(let v): return v
        case .array(let v): return v.map { $0.toAny() }
        case .dict(let v): return Dictionary(uniqueKeysWithValues: v.map { ($0.key, $0.value.toAny()) })
        }
    }
}

enum WQPlistFile {
    static func isBinary(_ data: Data) -> Bool { data.starts(with: Data("bplist00".utf8)) }

    static func load(_ url: URL) -> (value: WQPlistValue, binary: Bool)? {
        guard let data = try? Data(contentsOf: url),
              let any = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return (WQPlistValue.from(any), isBinary(data))
    }

    static func save(_ value: WQPlistValue, to url: URL, binary: Bool) -> Bool {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: value.toAny(), format: binary ? .binary : .xml, options: 0)
            try data.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}

// MARK: - SQLite (works on a copy + WAL, save-back guarded by integrity check)

final class WQSQLiteDB {
    let originalURL: URL
    private let workDir: URL
    private var db: OpaquePointer?
    private(set) var modified = false

    init?(originalURL: URL) {
        self.originalURL = originalURL
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mdm-sqlite-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: originalURL.path + suffix)
                if FileManager.default.fileExists(atPath: src.path) {
                    try FileManager.default.copyItem(at: src, to: tmp.appendingPathComponent(originalURL.lastPathComponent + suffix))
                }
            }
        } catch { return nil }
        self.workDir = tmp
        let copy = tmp.appendingPathComponent(originalURL.lastPathComponent)
        if sqlite3_open(copy.path, &db) != SQLITE_OK { return nil }
    }

    deinit {
        if let db { sqlite3_close(db) }
        try? FileManager.default.removeItem(at: workDir)
    }

    var copyURL: URL { workDir.appendingPathComponent(originalURL.lastPathComponent) }

    func tables() -> [(name: String, rows: Int)] {
        let sql = "SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        var stmt: OpaquePointer?
        var out: [(String, Int)] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            out.append((name, rowCount(of: name)))
        }
        return out
    }

    func rowCount(of table: String) -> Int {
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM \"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    struct QueryResult {
        let columns: [String]
        let rows: [[String]]
        let error: String?
    }

    func runQuery(_ sql: String) -> QueryResult {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return QueryResult(columns: [], rows: [], error: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let colCount = sqlite3_column_count(stmt)
        var columns: [String] = []
        for i in 0..<colCount { columns.append(String(cString: sqlite3_column_name(stmt, i))) }
        var rows: [[String]] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            var row: [String] = []
            for i in 0..<colCount {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_NULL: row.append("NULL")
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_blob(stmt, i)
                    let count = sqlite3_column_bytes(stmt, i)
                    row.append(bytes.map { Data(bytes: $0, count: Int(count)).map { String(format: "%02x", $0) }.joined() } ?? "")
                default:
                    row.append(sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "")
                }
                if rows.count >= 500 { break }
            }
            rows.append(row)
            if rows.count >= 500 { break }
            step = sqlite3_step(stmt)
        }
        if step != SQLITE_DONE && step != SQLITE_ROW {
            return QueryResult(columns: columns, rows: rows, error: String(cString: sqlite3_errmsg(db)))
        }
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !trimmed.hasPrefix("SELECT") && !trimmed.hasPrefix("PRAGMA") && !trimmed.hasPrefix("EXPLAIN") {
            modified = true
        }
        return QueryResult(columns: columns, rows: rows, error: nil)
    }

    func integrityOK() -> Bool {
        runQuery("PRAGMA integrity_check").rows.first?.first == "ok"
    }

    /// Writes the edited copy back over the original (after a safety backup).
    func saveBack() -> Bool {
        guard integrityOK() else { return false }
        WQBackups.backup(originalURL)
        if let db { sqlite3_close(db); self.db = nil }
        do {
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: copyURL.path + suffix)
                let dest = URL(fileURLWithPath: originalURL.path + suffix)
                if FileManager.default.fileExists(atPath: src.path) {
                    if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                    try FileManager.default.copyItem(at: src, to: dest)
                } else if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
            }
            modified = false
            return true
        } catch { return false }
    }
}

// MARK: - Text decoding (UTF-8 / UTF-16 / Latin-1 fallback + BOM strip)

enum WQTextFile {
    static func decode(_ data: Data) -> (text: String, encodingName: String) {
        var bytes = data
        if bytes.starts(with: Data([0xEF, 0xBB, 0xBF])) { bytes.removeFirst(3) }
        if let s = String(data: bytes, encoding: .utf8) { return (s, "UTF-8") }
        if let s = String(data: bytes, encoding: .utf16) { return (s, "UTF-16") }
        return (String(data: bytes, encoding: .isoLatin1) ?? "", "Latin-1")
    }
}
