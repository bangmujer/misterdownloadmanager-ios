import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

// iOS 16-compatible empty state (ContentUnavailableView needs iOS 17+).
struct WQEmptyState: View {
    let title: String
    let systemImage: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Get Info (size, dates, owner, permissions, inode, SHA-256)

struct WQGetInfoView: View {
    let url: URL
    @State private var sha256: String?
    @State private var folderSize: Int64?
    @State private var computing = false
    private var isDir: Bool { wqIsDirectory(url) }
    var body: some View {
        NavigationStack {
            List {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                LabeledContent("Nama", value: url.lastPathComponent)
                LabeledContent("Lokasi", value: url.deletingLastPathComponent().path)
                if isDir {
                    if let s = folderSize {
                        LabeledContent("Ukuran", value: formatBytes(s))
                    } else {
                        HStack { Text("Ukuran"); Spacer(); ProgressView() }
                    }
                } else {
                    LabeledContent("Ukuran", value: formatBytes(wqFileSize(url)))
                }
                if let d = attrs?[.creationDate] as? Date {
                    LabeledContent("Dibuat", value: d.formatted(date: .abbreviated, time: .standard))
                }
                if let d = attrs?[.modificationDate] as? Date {
                    LabeledContent("Diubah", value: d.formatted(date: .abbreviated, time: .standard))
                }
                if let owner = attrs?[.ownerAccountName] as? String {
                    LabeledContent("Pemilik", value: owner)
                }
                if let perms = attrs?[.posixPermissions] as? Int {
                    LabeledContent("Izin", value: String(format: "%o", perms))
                }
                if let inode = attrs?[.systemFileNumber] as? Int {
                    LabeledContent("Inode", value: "\(inode)")
                }
                if !isDir {
                    Section("SHA-256") {
                        if let sha256 {
                            Text(sha256).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .contextMenu { Button("Salin") { UIPasteboard.general.string = sha256 } }
                        } else {
                            HStack { Text("Menghitung…"); Spacer(); ProgressView() }
                        }
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if isDir {
                    folderSize = await wqFolderSize(url)
                } else {
                    sha256 = await Task.detached { wqSHA256(of: url) }.value
                }
            }
        }
    }
}

// MARK: - Text editor with syntax colors (read / edit, up to 1 MB)

struct WQTextEditorView: View {
    let url: URL
    @State private var text = ""
    @State private var encodingName = ""
    @State private var tooLarge = false
    @State private var editing = false
    @State private var savedMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if tooLarge {
                    WQEmptyState(title: "File terlalu besar", systemImage: "doc.text",
                        subtitle: "File di atas 1 MB hanya bisa dibaca sebagian, seperti di WQFiles.")
                } else if editing {
                    TextEditor(text: $text).font(.system(.body, design: .monospaced)).padding(4)
                } else {
                    ScrollView {
                        Text(highlighted(text, ext: url.pathExtension.lowercased()))
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding()
                    }
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if editing {
                        Button("Simpan") {
                            WQBackups.backup(url)
                            try? text.write(to: url, atomically: true, encoding: .utf8)
                            editing = false
                            savedMessage = "Tersimpan."
                        }
                    } else {
                        Button("Ubah") { editing = true }
                    }
                }
            }
            .alert("Tersimpan", isPresented: Binding(get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
                Button("OK", role: .cancel) { savedMessage = nil }
            } message: { Text(savedMessage ?? "") }
            .task {
                guard let data = try? Data(contentsOf: url) else { return }
                if data.count > 1_000_000 {
                    tooLarge = true
                    let head = data.prefix(1_000_000)
                    let decoded = WQTextFile.decode(head)
                    text = decoded.text
                    encodingName = decoded.encodingName
                } else {
                    let decoded = WQTextFile.decode(data)
                    text = decoded.text
                    encodingName = decoded.encodingName
                }
            }
        }
    }

    private func highlighted(_ source: String, ext: String) -> AttributedString {
        let attr = NSMutableAttributedString(string: source, attributes: [.foregroundColor: UIColor.label])
        func paint(_ pattern: String, color: UIColor, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                attr.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        paint(#"//.*|/\*[\s\S]*?\*/|#.*$"#, color: .secondaryLabel, options: [.anchorsMatchLines])
        paint(#""(?:\\.|[^"\\])*""#, color: .systemOrange)
        paint(#"\b\d+(?:\.\d+)?\b"#, color: .systemPurple)
        switch ext {
        case "swift", "js", "ts", "m", "c", "java", "kt", "go", "rs", "py", "sh", "rb", "lua":
            paint(#"\b(?:let|var|func|class|struct|enum|return|if|else|for|while|import|from|guard|switch|case|break|continue|do|try|catch|throw|async|await|self|nil|true|false|void|int|String|def|print|const|function|public|private|static|new)\b"#, color: .systemBlue)
        case "json", "plist", "xml", "yaml", "yml", "toml", "ini":
            paint(#""[^"]*"(?=\s*:)"#, color: .systemBlue)
        default:
            break
        }
        return AttributedString(attr)
    }
}

// MARK: - Plist editor (values by type, saves in the file's own format)

struct WQPlistEditorView: View {
    let url: URL
    @State private var root: WQPlistValue = .dict([])
    @State private var binary = false
    @State private var loadFailed = false
    @State private var savedMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if loadFailed {
                WQEmptyState(title: "Plist tidak bisa dibaca", systemImage: "exclamationmark.triangle",
                    subtitle: "File ini bukan property list yang valid.")
            } else {
                WQPlistNodeView(value: $root, title: url.lastPathComponent)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Simpan") {
                    WQBackups.backup(url)
                    if WQPlistFile.save(root, to: url, binary: binary) {
                        savedMessage = "Tersimpan dalam format \(binary ? "biner" : "XML") yang sama."
                    } else {
                        savedMessage = "Gagal menyimpan."
                    }
                }
            }
        }
        .alert("Simpan", isPresented: Binding(get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
            Button("OK", role: .cancel) { savedMessage = nil }
        } message: { Text(savedMessage ?? "") }
        .task {
            if let loaded = WQPlistFile.load(url) {
                root = loaded.value
                binary = loaded.binary
            } else {
                loadFailed = true
            }
        }
    }
}

struct WQPlistNodeView: View {
    @Binding var value: WQPlistValue
    let title: String
    @State private var newKey = ""
    @State private var newType = "String"

    var body: some View {
        List {
            switch value {
            case .dict(let pairs):
                Section("Dictionary (\(pairs.count))") {
                    ForEach(pairs.indices, id: \.self) { i in
                        HStack {
                            TextField("Kunci", text: dictKeyBinding(i))
                                .font(.system(.body, design: .monospaced))
                            NavigationLink(value: i) {
                                Text(pairs[i].value.typeLabel).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        if case .dict(var p) = value { p.remove(atOffsets: offsets); value = .dict(p) }
                    }
                    HStack {
                        TextField("Kunci baru", text: $newKey)
                        Picker("Tipe", selection: $newType) {
                            ForEach(["String", "Integer", "Real", "Boolean", "Date", "Data", "Array", "Dictionary"], id: \.self) { Text($0) }
                        }
                        .pickerStyle(.menu)
                        Button("Tambah") {
                            guard !newKey.isEmpty, case .dict(var p) = value else { return }
                            let v: WQPlistValue
                            switch newType {
                            case "Integer": v = .int(0)
                            case "Real": v = .double(0)
                            case "Boolean": v = .bool(false)
                            case "Date": v = .date(Date())
                            case "Data": v = .data(Data())
                            case "Array": v = .array([])
                            case "Dictionary": v = .dict([])
                            default: v = .string("")
                            }
                            p.append((key: newKey, value: v))
                            value = .dict(p)
                            newKey = ""
                        }
                    }
                }
            case .array(let items):
                Section("Array (\(items.count))") {
                    ForEach(items.indices, id: \.self) { i in
                        NavigationLink(value: i) {
                            Text("\(i): \(items[i].typeLabel)").foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        if case .array(var a) = value { a.remove(atOffsets: offsets); value = .array(a) }
                    }
                    Button("Tambah item (String)") {
                        if case .array(var a) = value { a.append(.string("")); value = .array(a) }
                    }
                }
            case .string(let s):
                TextField("Nilai", text: leafBinding(s, as: { .string($0) })).textFieldStyle(.roundedBorder)
            case .int(let n):
                TextField("Nilai", value: leafBinding(n, as: { .int($0) }), format: .number).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
            case .double(let d):
                TextField("Nilai", value: leafBinding(d, as: { .double($0) }), format: .number).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
            case .bool(let b):
                Toggle("Nilai", isOn: leafBinding(b, as: { .bool($0) }))
            case .date(let d):
                DatePicker("Nilai", selection: leafBinding(d, as: { .date($0) }))
            case .data(let d):
                Text(d.map { String(format: "%02x", $0) }.joined())
                    .font(.system(.body, design: .monospaced))
                Text("Data mentah hanya bisa dibaca di sini; pakai Hex Viewer untuk mengubah byte-nya.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        .navigationDestination(for: Int.self) { i in
            WQPlistNodeView(value: childBinding(i), title: childTitle(i))
        }
    }

    private func dictKeyBinding(_ i: Int) -> Binding<String> {
        Binding(get: {
            if case .dict(let p) = value, p.indices.contains(i) { return p[i].key }
            return ""
        }, set: { new in
            if case .dict(var p) = value, p.indices.contains(i) { p[i].key = new; value = .dict(p) }
        })
    }

    private func childBinding(_ i: Int) -> Binding<WQPlistValue> {
        Binding(get: {
            switch value {
            case .dict(let p): return p.indices.contains(i) ? p[i].value : .string("")
            case .array(let a): return a.indices.contains(i) ? a[i] : .string("")
            default: return value
            }
        }, set: { new in
            switch value {
            case .dict(var p): if p.indices.contains(i) { p[i].value = new; value = .dict(p) }
            case .array(var a): if a.indices.contains(i) { a[i] = new; value = .array(a) }
            default: value = new
            }
        })
    }

    private func childTitle(_ i: Int) -> String {
        switch value {
        case .dict(let p): return p.indices.contains(i) ? p[i].key : ""
        case .array: return "[\(i)]"
        default: return title
        }
    }

    private func leafBinding<T>(_ current: T, as wrap: @escaping (T) -> WQPlistValue) -> Binding<T> {
        Binding(get: { current }, set: { value = wrap($0) })
    }
}

// MARK: - Hex viewer / editor (paged, overwrite in place, size never changes)

struct WQHexEditorView: View {
    let url: URL
    private let pageSize = 4096
    @State private var page = 0
    @State private var bytes: [UInt8] = []
    @State private var totalSize: Int64 = 0
    @State private var changes: [Int: UInt8] = [:]
    @State private var selected: Int?
    @State private var editHex = ""
    @State private var jumpText = ""
    @State private var findText = ""
    @State private var statusMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var pageCount: Int { max(1, Int((totalSize + Int64(pageSize) - 1) / Int64(pageSize))) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Button { loadPage(max(0, page - 1)) } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
                    Text("Halaman \(page + 1) / \(pageCount)").font(.caption).monospacedDigit()
                    Button { loadPage(min(pageCount - 1, page + 1)) } label: { Image(systemName: "chevron.right") }.disabled(page >= pageCount - 1)
                    Spacer()
                    TextField("Ke offset", text: $jumpText).keyboardType(.numberPad).frame(width: 90)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    Button("Ke") { jumpToOffset() }
                }
                .padding(8)
                HStack {
                    TextField("Cari teks / hex (mis. DEADBEEF)", text: $findText).textFieldStyle(.roundedBorder).font(.caption)
                    Button("Cari") { findBytes() }
                }
                .padding(.horizontal, 8)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(stride(from: 0, to: bytes.count, by: 16)), id: \.self) { rowStart in
                            HStack(spacing: 4) {
                                Text(String(format: "%08X", page * pageSize + rowStart))
                                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                                ForEach(0..<16, id: \.self) { col in
                                    let idx = rowStart + col
                                    if idx < bytes.count {
                                        let shown = changes[idx] ?? bytes[idx]
                                        Button(String(format: "%02X", shown)) {
                                            selected = idx
                                            editHex = String(format: "%02X", shown)
                                        }
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(width: 22)
                                        .background(changes[idx] != nil ? Color.yellow.opacity(0.5) : (selected == idx ? Color.accentColor.opacity(0.25) : Color.clear))
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                    } else {
                                        Text("  ").font(.system(.caption, design: .monospaced)).frame(width: 22)
                                    }
                                }
                                Text(asciiRow(rowStart))
                                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8)
                }
                if let selected {
                    HStack {
                        Text("Offset \(page * pageSize + selected) (0x\(String(format: "%X", page * pageSize + selected)))").font(.caption).monospacedDigit()
                        TextField("HH", text: $editHex).frame(width: 44).textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button("Terapkan") {
                            if let v = UInt8(editHex, radix: 16) {
                                changes[selected] = v
                                self.selected = nil
                            }
                        }
                        Spacer()
                        if !changes.isEmpty {
                            Button("Simpan (\(changes.count) byte)") { saveChanges() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(8)
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .task { loadPage(0) }
            .alert("Hex", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) {
                Button("OK", role: .cancel) { statusMessage = nil }
            } message: { Text(statusMessage ?? "") }
        }
    }

    private func asciiRow(_ rowStart: Int) -> String {
        (0..<16).map { col in
            let idx = rowStart + col
            guard idx < bytes.count else { return " " }
            let b = changes[idx] ?? bytes[idx]
            return (32...126).contains(Int(b)) ? String(UnicodeScalar(b)) : "."
        }.joined()
    }

    private func loadPage(_ p: Int) {
        page = p
        changes.removeAll()
        selected = nil
        totalSize = wqFileSize(url)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(p * pageSize))
        bytes = Array((try? handle.read(upToCount: pageSize)) ?? Data())
    }

    private func jumpToOffset() {
        guard let offset = Int(jumpText), offset >= 0, offset < Int(totalSize) else {
            statusMessage = "Offset di luar file."
            return
        }
        loadPage(offset / pageSize)
        selected = offset % pageSize
        editHex = String(format: "%02X", bytes[selected ?? 0])
    }

    private func findBytes() {
        guard !findText.isEmpty else { return }
        let needle: [UInt8]
        if findText.allSatisfy({ $0.isHexDigit }) && findText.count % 2 == 0 && findText.count >= 4 {
            var out: [UInt8] = []
            var i = findText.startIndex
            while i < findText.endIndex {
                let next = findText.index(i, offsetBy: 2)
                out.append(UInt8(findText[i..<next], radix: 16) ?? 0)
                i = next
            }
            needle = out
        } else {
            needle = Array(findText.utf8)
        }
        Task.detached {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            var offset = 0
            var tail = Data()
            let needleData = Data(needle)
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                let combined = tail + chunk
                if let range = combined.range(of: needleData) {
                    let found = offset - tail.count + range.lowerBound
                    await MainActor.run {
                        loadPage(found / pageSize)
                        selected = found % pageSize
                        editHex = String(format: "%02X", bytes[selected ?? 0])
                    }
                    return
                }
                tail = combined.suffix(max(0, needle.count - 1))
                offset += chunk.count
            }
            await MainActor.run { statusMessage = "Tidak ditemukan." }
        }
    }

    private func saveChanges() {
        WQBackups.backup(url)
        guard let handle = try? FileHandle(forUpdating: url) else {
            statusMessage = "Gagal membuka file untuk ditulis."
            return
        }
        defer { try? handle.close() }
        do {
            for (idx, byte) in changes {
                try handle.seek(toOffset: UInt64(page * pageSize + idx))
                try handle.write(contentsOf: Data([byte]))
            }
            changes.removeAll()
            loadPage(page)
            statusMessage = "Tersimpan (ukuran file tidak berubah)."
        } catch {
            statusMessage = "Gagal menyimpan: \(error.localizedDescription)"
        }
    }
}

// MARK: - SQLite viewer (copy + WAL; edits guarded by integrity check on save)

struct WQSQLiteViewerView: View {
    let url: URL
    @State private var db: WQSQLiteDB?
    @State private var openFailed = false
    @State private var sql = ""
    @State private var result: WQSQLiteDB.QueryResult?
    @State private var selectedTable: String?
    @State private var saveMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if openFailed {
                    WQEmptyState(title: "Database tidak bisa dibuka", systemImage: "exclamationmark.triangle",
                        subtitle: "File ini bukan database SQLite yang valid.")
                } else if let db {
                    List {
                        Section("Tabel & View") {
                            ForEach(db.tables(), id: \.name) { table in
                                NavigationLink(value: table.name) {
                                    HStack {
                                        Text(table.name)
                                        Spacer()
                                        Text("\(table.rows) baris").foregroundStyle(.secondary).font(.caption)
                                    }
                                }
                            }
                        }
                        Section("Query SQL (berjalan di salinan)") {
                            TextField("SELECT * FROM …", text: $sql, axis: .vertical).font(.system(.body, design: .monospaced))
                            Button("Jalankan") { result = db.runQuery(sql) }
                            if let result {
                                if let error = result.error {
                                    Text(error).foregroundStyle(.red).font(.caption)
                                } else {
                                    WQSQLiteGrid(result: result)
                                    Button("Ekspor CSV") { exportCSV(result) }
                                }
                            }
                        }
                        if db.modified {
                            Section {
                                Text("Salinan sudah diubah. Simpan untuk menulis kembali ke file asli (cek integritas dulu, file asli dicadangkan).")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Simpan kembali ke file asli") {
                                    saveMessage = db.saveBack() ? "Tersimpan dan lolos integrity check." : "Gagal: integrity check tidak lolos atau file berubah."
                                }
                            }
                        }
                    }
                    .navigationDestination(for: String.self) { table in
                        WQSQLiteTableView(db: db, table: table)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if let opened = WQSQLiteDB(originalURL: url) {
                    db = opened
                } else {
                    openFailed = true
                }
            }
            .alert("Simpan", isPresented: Binding(get: { saveMessage != nil }, set: { if !$0 { saveMessage = nil } })) {
                Button("OK", role: .cancel) { saveMessage = nil }
            } message: { Text(saveMessage ?? "") }
        }
    }

    private func exportCSV(_ result: WQSQLiteDB.QueryResult) {
        var lines = [result.columns.map(csvEscape).joined(separator: ",")]
        lines += result.rows.map { $0.map(csvEscape).joined(separator: ",") }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".csv")
        try? lines.joined(separator: "\n").write(to: dest, atomically: true, encoding: .utf8)
        let activity = UIActivityViewController(activityItems: [dest], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(activity, animated: true)
        }
    }

    private func csvEscape(_ s: String) -> String {
        s.contains(",") || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}

struct WQSQLiteGrid: View {
    let result: WQSQLiteDB.QueryResult
    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    ForEach(result.columns, id: \.self) { Text($0).bold().font(.caption) }
                }
                Divider()
                ForEach(result.rows.indices, id: \.self) { r in
                    HStack(spacing: 12) {
                        ForEach(result.rows[r].indices, id: \.self) { c in
                            Text(result.rows[r][c]).font(.caption).lineLimit(1)
                        }
                    }
                }
                if result.rows.isEmpty { Text("Tidak ada baris.").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4)
        }
    }
}

struct WQSQLiteTableView: View {
    let db: WQSQLiteDB
    let table: String
    @State private var page = 0
    @State private var result: WQSQLiteDB.QueryResult?
    private let pageSize = 100

    var body: some View {
        List {
            if let result {
                WQSQLiteGrid(result: result)
            }
            HStack {
                Button("Sebelumnya") { page = max(0, page - 1); load() }.disabled(page == 0)
                Spacer()
                Text("Halaman \(page + 1)").font(.caption)
                Spacer()
                Button("Berikutnya") { page += 1; load() }.disabled((result?.rows.count ?? 0) < pageSize)
            }
        }
        .navigationTitle(table)
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private func load() {
        let safe = table.replacingOccurrences(of: "\"", with: "\"\"")
        result = db.runQuery("SELECT * FROM \"\(safe)\" LIMIT \(pageSize) OFFSET \(page * pageSize)")
    }
}

// MARK: - Backups & Recently Deleted

struct WQBackupsView: View {
    @State private var entries: [WQBackups.Entry] = []
    @State private var restoreTarget: WQBackups.Entry?
    @State private var showOverwriteConfirm = false

    var body: some View {
        NavigationStack {
            List {
                let deleted = entries.filter { !$0.originalExists }
                if !deleted.isEmpty {
                    Section("Baru dihapus") {
                        ForEach(deleted) { entry in backupRow(entry) }
                    }
                }
                Section("Semua cadangan") {
                    if entries.isEmpty {
                        Text("Belum ada cadangan. File yang dihapus atau ditimpa akan dicadangkan dulu di sini.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in backupRow(entry) }
                }
            }
            .navigationTitle("Cadangan")
            .navigationBarTitleDisplayMode(.inline)
            .task { entries = WQBackups.entries() }
            .confirmationDialog("File asli masih ada. Timpa dengan cadangan ini?", isPresented: $showOverwriteConfirm, titleVisibility: .visible) {
                Button("Timpa & Pulihkan", role: .destructive) {
                    if let t = restoreTarget, WQBackups.restore(t) { entries = WQBackups.entries() }
                    restoreTarget = nil
                }
                Button("Batal", role: .cancel) { restoreTarget = nil }
            }
        }
    }

    private func backupRow(_ entry: WQBackups.Entry) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(entry.displayName).lineLimit(1)
                Text(entry.originalPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Pulihkan") {
                restoreTarget = entry
                if entry.originalExists { showOverwriteConfirm = true }
                else if WQBackups.restore(entry) { entries = WQBackups.entries() }
            }
            .buttonStyle(.bordered)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Hapus cadangan", role: .destructive) {
                WQBackups.deleteBackup(entry)
                entries = WQBackups.entries()
            }
        }
    }
}

// MARK: - Search inside folders / Largest files

struct WQSearchResultsView: View {
    let root: URL
    let query: String
    @State private var hits: [URL] = []
    @State private var done = false
    var body: some View {
        NavigationStack {
            List {
                if hits.isEmpty && !done {
                    ProgressView("Mencari…")
                } else if hits.isEmpty {
                    Text("Tidak ada file bernama \"\(query)\" di dalam folder ini.").foregroundStyle(.secondary)
                } else {
                    ForEach(hits, id: \.self) { url in
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle("Hasil pencarian")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                hits = await wqSearch(in: root, matching: query)
                done = true
            }
        }
    }
}

struct WQLargestFilesView: View {
    let root: URL
    @State private var items: [(url: URL, size: Int64)] = []
    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    ProgressView("Mengukur…")
                } else {
                    ForEach(items, id: \.url) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.url.lastPathComponent).lineLimit(1)
                                Text(item.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(formatBytes(item.size)).font(.caption).monospacedDigit()
                        }
                    }
                }
            }
            .navigationTitle("File terbesar")
            .navigationBarTitleDisplayMode(.inline)
            .task { items = await wqLargestFiles(in: root) }
        }
    }
}

// MARK: - Compress helper (ZIP via ZIPFoundation)

enum WQZip {
    static func compress(_ urls: [URL], to dest: URL) throws {
        let archive = try Archive(url: dest, accessMode: .create)
        for url in urls {
            if wqIsDirectory(url) {
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
                for case let file as URL in enumerator where !wqIsDirectory(file) {
                    let rel = file.path.dropFirst(url.deletingLastPathComponent().path.count + 1)
                    try archive.addEntry(with: String(rel), relativeTo: url.deletingLastPathComponent(), compressionMethod: .deflate)
                }
            } else {
                try archive.addEntry(with: url.lastPathComponent, relativeTo: url.deletingLastPathComponent(), compressionMethod: .deflate)
            }
        }
    }
}
