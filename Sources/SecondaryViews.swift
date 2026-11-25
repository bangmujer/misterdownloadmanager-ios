import SwiftUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - Settings

/// A fill-in numeric field for Settings rows: type the number directly
/// instead of tapping a stepper. Digits are committed as typed; the value
/// is clamped to the range when editing ends (live clamping would fight
/// typing, e.g. a port starting with "8" is below the 1024 minimum).
private struct IntField: View {
    var label: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var suffix: String = ""
    @State private var text: String
    @FocusState private var focused: Bool

    init(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>, suffix: String = "") {
        self.label = label
        self._value = value
        self.range = range
        self.suffix = suffix
        self._text = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .frame(width: 80)
                .onChange(of: text) { newValue in
                    let digits = newValue.filter(\.isNumber)
                    if digits != newValue { text = digits; return }
                    if let n = Int(digits) { value = n }
                }
                .onChange(of: focused) { isFocused in
                    if !isFocused { commit() }
                }
                .onChange(of: value) { newValue in
                    if !focused, text != String(newValue) { text = String(newValue) }
                }
                .onDisappear { commit() }
            if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Selesai") { focused = false }
            }
        }
    }

    private func commit() {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
        if text != String(clamped) { text = String(clamped) }
    }
}

/// Speed-limit row: a dropdown of presets (including unlimited) plus a
/// custom value with a KB/MB/GB unit choice. Stored as KB/s; 0 means
/// unlimited.
private struct SpeedLimitRow: View {
    @Binding var kbps: Int
    @State private var customUnit: Int
    @State private var previousUnit: Int

    private static let presets: [Int] = [0, 100, 256, 512, 1024, 5120, 10240, 51200, 102400, 1048576]

    init(kbps: Binding<Int>) {
        self._kbps = kbps
        let unit = Self.unit(for: kbps.wrappedValue)
        self._customUnit = State(initialValue: unit)
        self._previousUnit = State(initialValue: unit)
    }

    private static func multiplier(_ unit: Int) -> Int { unit == 2 ? 1048576 : unit == 1 ? 1024 : 1 }

    /// Largest unit that divides the value exactly, so entering custom
    /// mode never changes the stored limit.
    private static func unit(for value: Int) -> Int {
        if value > 0, value % 1048576 == 0 { return 2 }
        if value >= 1024, value % 1024 == 0 { return 1 }
        return 0
    }

    private static func presetLabel(_ value: Int) -> String {
        if value == 0 { return "Tanpa batas" }
        if value == 1048576 { return "1 GB/s" }
        if value >= 1024 { return "\(value / 1024) MB/s" }
        return "\(value) KB/s"
    }

    private var presetSelection: Binding<Int> {
        Binding(
            get: { kbps == 0 || Self.presets.contains(kbps) ? kbps : -1 },
            set: { new in
                if new == -1 {
                    let unit = Self.unit(for: kbps)
                    customUnit = unit
                    previousUnit = unit
                } else {
                    kbps = new
                }
            }
        )
    }

    private var customValue: Binding<Int> {
        let mult = Self.multiplier(customUnit)
        return Binding(
            get: { kbps / mult },
            set: { kbps = min(max($0, 0), 1048576 / mult) * mult }
        )
    }

    var body: some View {
        Picker("Speed limit", selection: presetSelection) {
            ForEach(Self.presets, id: \.self) { Text(Self.presetLabel($0)).tag($0) }
            Text("Kustom…").tag(-1)
        }
        if presetSelection.wrappedValue == -1 {
            IntField("Kecepatan kustom", value: customValue, in: 0...(1048576 / Self.multiplier(customUnit)))
            Picker("Satuan", selection: $customUnit) {
                Text("KB/s").tag(0); Text("MB/s").tag(1); Text("GB/s").tag(2)
            }
            .pickerStyle(.segmented)
            .onChange(of: customUnit) { newUnit in
                let display = kbps / Self.multiplier(previousUnit)
                kbps = display * Self.multiplier(newUnit)
                previousUnit = newUnit
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    /// In the bottom tab bar there is nothing to dismiss, so the Done
    /// button is hidden; as a sheet it stays.
    var showsDoneButton: Bool = true
    @State private var cacheBytes: Int64 = 0
    @State private var cacheMessage: String?
    var body: some View {
        // In the tab bar the system (Lainnya overflow) navigation
        // already provides the bar — a second NavigationStack here
        // stacked a second bar under the back button and pushed the
        // title far down. As a sheet there is no outer bar, so the
        // stack (and the Done button) stays.
        Group {
            if showsDoneButton {
                NavigationStack { settingsForm }
            } else {
                settingsForm
            }
        }
    }

    private var settingsForm: some View {
        Form {
                Section("Download") {
                    HStack {
                        Text("Max connections per download")
                        Slider(value: Binding(get: { Double(store.settings.maxConnections) }, set: { store.settings.maxConnections = Int($0) }), in: 1...60, step: 1)
                        Text("\(store.settings.maxConnections)").frame(width: 28, alignment: .trailing)
                    }
                    Picker("Max concurrent downloads", selection: $store.settings.maxConcurrentDownloads) {
                        ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                    }
                    SpeedLimitRow(kbps: $store.settings.speedLimitKBps)
                    Toggle("Start downloads paused", isOn: $store.settings.startPaused)
                    Toggle("Auto-resume on launch", isOn: $store.settings.autoResumeOnLaunch)
                    TextField("User-Agent", text: $store.settings.userAgent)
                }
                Section("Queue & Scheduler") {
                    Toggle("Queue enabled", isOn: $store.settings.queueEnabled)
                    Toggle("Scheduler enabled", isOn: $store.settings.schedulerEnabled)
                    Picker("Start", selection: $store.settings.schedulerStartHour) {
                        ForEach(0..<24, id: \.self) { Text("\($0):\(String(format: "%02d", store.settings.schedulerStartMinute))").tag($0) }
                    }
                    Picker("Stop", selection: $store.settings.schedulerStopHour) {
                        ForEach(0..<24, id: \.self) { Text("\($0):\(String(format: "%02d", store.settings.schedulerStopMinute))").tag($0) }
                    }
                    Text("iOS cannot wake the phone or shut it down like the desktop scheduler. The window only gates starting/pausing while the app runs, and background downloads are limited by iOS.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Penyimpanan") {
                    LabeledContent("Cache download", value: formatBytes(cacheBytes))
                    Button("Hapus Cache") {
                        let freed = store.clearDownloadCache()
                        cacheBytes = store.downloadCacheSize()
                        cacheMessage = freed > 0 ? "Cache dibersihkan, \(formatBytes(freed)) dibebaskan." : "Tidak ada cache yang perlu dibersihkan."
                    }
                    if let cacheMessage {
                        Text(cacheMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Menghapus sisa file sementara (.part dan potongan segmen) dari download yang sudah dihapus atau selesai. File .part milik download yang masih antre, jeda, atau gagal dipertahankan agar bisa dilanjutkan.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Debrid — your own keys") {
                    SecureField("Real-Debrid API key", text: $store.settings.realDebridKey)
                    SecureField("AllDebrid API key", text: $store.settings.allDebridKey)
                    SecureField("Premiumize API key", text: $store.settings.premiumizeKey)
                    SecureField("TorBox token", text: $store.settings.torboxKey)
                    SecureField("Mega-Debrid token", text: $store.settings.megaDebridKey)
                    Text("Keys stay in this app's settings file on this device. Debrid is experimental in the desktop app too.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Jaringan") {
                    Toggle("Wi-Fi only (kill-switch approximation)", isOn: $store.settings.wifiOnly)
                    Toggle("Use proxy", isOn: $store.settings.proxyEnabled)
                    Picker("Proxy type", selection: $store.settings.proxyType) { Text("HTTP").tag("HTTP"); Text("SOCKS").tag("SOCKS") }
                    TextField("Proxy host", text: $store.settings.proxyHost)
                    IntField("Proxy port", value: $store.settings.proxyPort, in: 1...65535)
                    TextField("Custom DNS (stored only)", text: $store.settings.customDNS)
                    Text("iOS URLSession cannot override DNS per app, so a custom DNS value is stored for reference only and does not change resolution.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Appearance, Language & Scale") {
                    Picker("Theme", selection: $store.settings.themeName) {
                        ForEach(ThemeName.pickerCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Language", selection: $store.settings.language) {
                        Text("English").tag("en"); Text("Bahasa Indonesia").tag("id"); Text("العربية (RTL)").tag("ar"); Text("Français").tag("fr"); Text("Deutsch").tag("de"); Text("日本語").tag("ja")
                    }
                    Text("The main UI follows the Language choice (Indonesian and English). Some deep or technical screens are still English; more strings are translated over time.").font(.caption).foregroundStyle(.secondary)
                    HStack { Text("Interface scale"); Slider(value: $store.settings.interfaceScale, in: 0.8...2.0, step: 0.1); Text("\(Int(store.settings.interfaceScale * 100))%") }
                }
                Section("Notifications & Clipboard") {
                    Toggle("Download notifications", isOn: $store.settings.notificationsEnabled)
                    Toggle("Watch clipboard for links", isOn: $store.settings.clipboardMonitor)
                }
                Section("Remote control (LAN)") {
                    Toggle("Enable remote control", isOn: $store.settings.remoteControlEnabled)
                    IntField("Port", value: $store.settings.remotePort, in: 1024...65535)
                    if let addr = store.remoteAddress { LabeledContent("Address", value: addr) }
                    Text("Plain HTTP on trusted home Wi-Fi only, while the app is in the foreground. The desktop remote uses HTTPS pairing; that pairing flow is not ported.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Browser — Umum") {
                    Picker("Search engine", selection: $store.browserSettings.searchEngine) {
                        ForEach(SearchEngine.all, id: \.self) { engine in
                            Text(engine).tag(engine)
                        }
                    }
                    Picker("User Agent", selection: $store.browserSettings.userAgentPreset) {
                        ForEach(UserAgentPreset.allCases) { preset in
                            Text(preset.label).tag(preset.rawValue)
                        }
                    }
                    TextField("Home page", text: $store.browserSettings.homePage)
                        .autocapitalization(.none).autocorrectionDisabled()
                }
                Section("Kata Sandi") {
                    NavigationLink("Kata Sandi tersimpan") { PasswordsView() }
                    Text("Username dan kata sandi yang disimpan dari formulir login di browser. Kata sandi hanya tersimpan di Keychain perangkat ini, dan melihat, menyalin, atau mengisinya selalu meminta Face ID (atau kode sandi perangkat).").font(.caption).foregroundStyle(.secondary)
                }
                Section("Browser — AdBlock") {
                    Toggle("Ghostery AdBlock (EasyList + EasyPrivacy)", isOn: $store.browserSettings.adBlockEnabled)
                    Toggle("Custom AdBlock (your URL filters)", isOn: $store.browserSettings.customAdBlockEnabled)
                    Text("Filter kustom dan allowlist diatur di panel perisai di dalam browser. The in-app browser runs both AdBlock lists together and captures downloads straight into the queue.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Browser — Media") {
                    Toggle("Putar di background (termasuk YouTube)", isOn: $store.browserSettings.backgroundPlayback)
                    Toggle("Picture in Picture", isOn: $store.browserSettings.pictureInPicture)
                    Text("Background dan PiP butuh mode audio di sistem; mematikannya mengembalikan perilaku normal browser (media berhenti saat aplikasi ditutup).").font(.caption).foregroundStyle(.secondary)
                }
                Section("Browser — Konten") {
                    Toggle("Blokir popup", isOn: $store.browserSettings.blockPopups)
                    Toggle("Tampilkan pratinjau link (tekan lama)", isOn: $store.browserSettings.linkPreview)
                    Toggle("Deteksi alamat (buka di Google Maps)", isOn: $store.browserSettings.detectAddresses)
                    Toggle("Web Inspector (periksa dari Safari di Mac)", isOn: $store.browserSettings.webInspector)
                    Toggle("Tampilkan tombol DevTools di browser", isOn: $store.browserSettings.showDevToolsButton)
                    Text("Kalau aktif, tombol DevTools melayang di atas halaman dan entri DevTools muncul di menu ⋯. Panelnya tampil sebagai sheet bawah gaya DevSnoop (Console, Network, Elements, Storage).").font(.caption).foregroundStyle(.secondary)
                    Toggle("Lewati timer tunggu (countdown download)", isOn: $store.browserSettings.skipTimers)
                    Toggle("Tanpa redirect (klik download langsung ke link final)", isOn: $store.browserSettings.noRedirects)
                    Text("Blokir popup menahan jendela yang dibuka script (window.open); tautan yang diketuk tetap dibuka. Lewati timer mempercepat hitung mundur di halaman download sampai 50x dan mengaktifkan tombol download yang dikunci timer; timer yang ditegakkan server dan verifikasi manusia (mis. Cloudflare) tidak bisa dilewati. Tanpa redirect membuat klik tombol download langsung membuka link finalnya dan membuang popup ke situs lain; popup login/pembayaran yang sah bisa ikut tertahan, matikan kalau perlu.").font(.caption).foregroundStyle(.secondary)
                }
                Section("About & honest limits") {
                    Text("Mister Download Manager — iOS port. Original: github.com/anefzaoui/misterdownloadmanager, GPL-3.0, Rust/egui desktop app for Windows/Mac/Linux. This SwiftUI reimplementation keeps the download engine ideas (segmentation, resume, categories, queues, scheduler window, debrid, video grabber, torrent metadata, remote control) within iOS sandbox limits.")
                    Text("Not ported: Chrome extensions and the desktop browser native-messaging host (the in-app browser captures downloads itself instead), system tray, wake/shutdown, yt-dlp/ffmpeg video processing, 7z/RAR via 7-Zip, MCP server, CLI switches, DHT/uTP/UPnP torrenting and background seeding, screen-reader-perfect desktop menus. Nothing here pretends those work.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Original repository", destination: URL(string: "https://github.com/anefzaoui/misterdownloadmanager")!)
                    Link("License: GPL-3.0", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                }
            }
            .onChange(of: store.settings.language) { _ in store.save() }
            .toolbar {
                ToolbarItem(placement: .principal) { Text("Options") }
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { store.save(); dismiss() } }
                }
            }
            .onAppear { cacheBytes = store.downloadCacheSize() }
            .onReceive(store.$settings.dropFirst()) { _ in store.save() }
            .onReceive(store.$browserSettings.dropFirst()) { _ in store.saveBrowserSettings() }
    }
}

// MARK: - Downloaded files
// MARK: - My Files: WQFiles-style browser over the app's own sandbox
//
// Merged here (not a separate tab) because it IS the file browser: the same
// Downloads folder, upgraded with WQFiles' Files-tool behaviour — folder
// navigation, sort, in-folder search, largest files, favorites, Get Info,
// Open As (text / plist / hex / SQLite), duplicate, compress, move, import,
// and backups-before-delete with Recently Deleted. Cross-app containers,
// the Apps manager and the cross-app Cache Cleaner are NOT here: they need
// the worse_query sandbox technique (iOS 26–27.3 beta 1, patched in 27.3
// beta 2), which cannot work on this app's iOS 16+ / TrollStore install.

enum WQLocation: String, CaseIterable, Identifiable {
    case downloads, documents, library, caches, tmp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .downloads: return "Downloads"
        case .documents: return "Documents"
        case .library: return "Library"
        case .caches: return "Caches"
        case .tmp: return "tmp"
        }
    }
    var url: URL {
        let fm = FileManager.default
        switch self {
        case .downloads:
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        case .documents:
            return fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        case .library:
            return fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        case .caches:
            return fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        case .tmp:
            return fm.temporaryDirectory
        }
    }
}

enum WQSheet: Identifiable {
    case info(URL), text(URL), plist(URL), hex(URL), sqlite(URL)
    case backups, search(URL, String), largest(URL)
    var id: String {
        switch self {
        case .info(let u): return "info-\(u.path)"
        case .text(let u): return "text-\(u.path)"
        case .plist(let u): return "plist-\(u.path)"
        case .hex(let u): return "hex-\(u.path)"
        case .sqlite(let u): return "sqlite-\(u.path)"
        case .backups: return "backups"
        case .search(let u, let q): return "search-\(u.path)-\(q)"
        case .largest(let u): return "largest-\(u.path)"
        }
    }
}

@MainActor
final class WQBrowserState: ObservableObject {
    @Published var path: [URL] = []
    @Published var location: WQLocation = .downloads
    @Published var sort: WQSort = .name
    @Published var ascending = true
    @Published var searchText = ""
    @Published var selection = Set<URL>()
    @Published var moveItems: [URL]?
    @Published var previewURL: URL?
    @Published var sheet: WQSheet?
    @Published var refreshTick = 0
    @Published var renameTarget: URL?
    @Published var renameText = ""
    @Published var pendingDelete: URL?
    @Published var pendingDeleteMany: [URL]?
    @Published var pendingExtract: URL?
    @Published var showCreateFolder = false
    @Published var newFolderName = ""
    @Published var showImporter = false
    @Published var notice: String?

    func bump() { refreshTick += 1 }
    func currentDir(root: URL) -> URL { path.last ?? root }

    func delete(_ url: URL) {
        WQBackups.backup(url)
        try? FileManager.default.removeItem(at: url)
        bump()
    }

    func dedupedURL(in dir: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = dir.appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }
}

struct DownloadedFilesView: View {
    @EnvironmentObject var store: DownloadStore
    @StateObject private var browser = WQBrowserState()
    var body: some View {
        NavigationStack(path: $browser.path) {
            WQDirView(dir: browser.location.url, root: browser.location.url, browser: browser)
                .navigationDestination(for: URL.self) { dir in
                    WQDirView(dir: dir, root: browser.location.url, browser: browser)
                }
        }
        .quickLookPreview($browser.previewURL)
        .sheet(item: $browser.sheet) { sheet in
            switch sheet {
            case .info(let u): WQGetInfoView(url: u)
            case .text(let u): WQTextEditorView(url: u)
            case .plist(let u): WQPlistEditorView(url: u)
            case .hex(let u): WQHexEditorView(url: u)
            case .sqlite(let u): WQSQLiteViewerView(url: u)
            case .backups: WQBackupsView()
            case .search(let dir, let q): WQSearchResultsView(root: dir, query: q)
            case .largest(let dir): WQLargestFilesView(root: dir)
            }
        }
        .alert("Ubah nama", isPresented: Binding(get: { browser.renameTarget != nil }, set: { if !$0 { browser.renameTarget = nil } })) {
            TextField("Nama baru", text: $browser.renameText)
            Button("Ubah") {
                if let old = browser.renameTarget, !browser.renameText.isEmpty {
                    let dest = old.deletingLastPathComponent().appendingPathComponent(browser.renameText)
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        try? FileManager.default.moveItem(at: old, to: dest)
                        browser.bump()
                    }
                }
                browser.renameTarget = nil
            }
            Button("Batal", role: .cancel) { browser.renameTarget = nil }
        }
        .alert("Buat folder", isPresented: $browser.showCreateFolder) {
            TextField("Nama folder", text: $browser.newFolderName)
            Button("Buat") {
                if !browser.newFolderName.isEmpty {
                    let dir = browser.currentDir(root: browser.location.url).appendingPathComponent(browser.newFolderName, isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    browser.bump()
                }
                browser.newFolderName = ""
            }
            Button("Batal", role: .cancel) { browser.newFolderName = "" }
        }
        .confirmationDialog("Hapus file ini? Salinannya dicadangkan dulu.", isPresented: Binding(get: { browser.pendingDelete != nil }, set: { if !$0 { browser.pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Hapus", role: .destructive) {
                if let u = browser.pendingDelete { browser.delete(u) }
                browser.pendingDelete = nil
            }
            Button("Batal", role: .cancel) { browser.pendingDelete = nil }
        }
        .confirmationDialog("Hapus \(browser.pendingDeleteMany?.count ?? 0) item? Salinannya dicadangkan dulu.", isPresented: Binding(get: { browser.pendingDeleteMany != nil }, set: { if !$0 { browser.pendingDeleteMany = nil } }), titleVisibility: .visible) {
            Button("Hapus semua", role: .destructive) {
                browser.pendingDeleteMany?.forEach { browser.delete($0) }
                browser.pendingDeleteMany = nil
                browser.selection.removeAll()
            }
            Button("Batal", role: .cancel) { browser.pendingDeleteMany = nil }
        }
        .confirmationDialog("Ekstrak ZIP ini ke folder baru?", isPresented: Binding(get: { browser.pendingExtract != nil }, set: { if !$0 { browser.pendingExtract = nil } }), titleVisibility: .visible) {
            Button("Ekstrak") {
                if let zip = browser.pendingExtract {
                    let dest = browser.dedupedURL(in: zip.deletingLastPathComponent(), name: zip.deletingPathExtension().lastPathComponent)
                    if (try? ArchiveExtractor.extract(zipURL: zip, to: dest)) != nil { browser.bump() }
                    else { browser.notice = "Gagal mengekstrak ZIP." }
                }
                browser.pendingExtract = nil
            }
            Button("Batal", role: .cancel) { browser.pendingExtract = nil }
        }
        .alert("My Files", isPresented: Binding(get: { browser.notice != nil }, set: { if !$0 { browser.notice = nil } })) {
            Button("OK", role: .cancel) { browser.notice = nil }
        } message: { Text(browser.notice ?? "") }
        .fileImporter(isPresented: $browser.showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let dir = browser.currentDir(root: browser.location.url)
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let dest = browser.dedupedURL(in: dir, name: url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: dest)
            }
            browser.bump()
        }
        .environmentObject(browser)
    }
}

struct WQDirView: View {
    let dir: URL
    let root: URL
    @ObservedObject var browser: WQBrowserState
    @EnvironmentObject var store: DownloadStore
    @Environment(\.editMode) private var editMode
    private var isEditing: Bool { editMode?.wrappedValue == .active }

    private var items: [URL] {
        _ = browser.refreshTick
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey])) ?? []
        let filtered = browser.searchText.isEmpty ? contents : contents.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(browser.searchText) }
        return wqSortContents(filtered, by: browser.sort, ascending: browser.ascending)
    }
    private var isRoot: Bool { dir == root }

    var body: some View {
        List {
            if isRoot {
                let favorites = WQFavorites.all()
                if !favorites.isEmpty {
                    Section("Favorit") {
                        ForEach(favorites, id: \.self) { fav in
                            row(fav, isFavorite: true)
                        }
                    }
                }
            }
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Folder kosong").font(.headline)
                    Text("File hasil download dan file yang diimpor muncul di sini.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding()
            }
            ForEach(items, id: \.self) { url in
                row(url, isFavorite: false)
            }
        }
        .navigationTitle(isRoot ? "My Files" : dir.lastPathComponent)
        .searchable(text: $browser.searchText, prompt: "Cari di folder ini")
        .onChange(of: isEditing) { editing in
            // A stale selection must never block taps: leaving Edit mode clears it.
            if !editing { browser.selection.removeAll() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !browser.selection.isEmpty {
                    Menu("Pilihan (\(browser.selection.count))") {
                        Button("Pindahkan…") {
                            browser.moveItems = Array(browser.selection)
                            browser.selection.removeAll()
                        }
                        Button("Kompres jadi ZIP") { compress(Array(browser.selection)) }
                        Button("Hapus", role: .destructive) { browser.pendingDeleteMany = Array(browser.selection) }
                    }
                }
                Menu {
                    Picker("Urutkan", selection: $browser.sort) {
                        ForEach(WQSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Button(browser.ascending ? "Z ke A / Terbaru dulu" : "A ke Z / Terlama dulu") { browser.ascending.toggle() }
                    Divider()
                    Button("Cari di dalam folder…") { browser.sheet = .search(dir, browser.searchText) }
                    Button("File terbesar") { browser.sheet = .largest(dir) }
                    Divider()
                    Button("Folder baru") { browser.showCreateFolder = true }
                    Button("Impor file…") { browser.showImporter = true }
                    Divider()
                    Picker("Lokasi", selection: $browser.location) {
                        ForEach(WQLocation.allCases) { Text($0.label).tag($0) }
                    }
                    Button("Cadangan & Baru dihapus") { browser.sheet = .backups }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onChange(of: browser.location) { _ in browser.path.removeAll() }
        .safeAreaInset(edge: .bottom) {
            if let moving = browser.moveItems {
                HStack {
                    Text("Pindahkan \(moving.count) item ke folder ini?")
                    Spacer()
                    Button("Pindahkan") { moveHere(moving, to: dir) }
                        .buttonStyle(.borderedProminent)
                    Button("Batal", role: .cancel) { browser.moveItems = nil }
                }
                .padding()
                .background(.thinMaterial)
            }
        }
    }

    private func row(_ url: URL, isFavorite: Bool) -> some View {
        let isDir = wqIsDirectory(url)
        return Group {
            if isDir {
                // Folders navigate on tap, always — via the path, not a
                // NavigationLink, so List selection can never swallow the tap.
                // In Edit mode the same tap toggles selection instead.
                Button {
                    if isEditing {
                        if browser.selection.contains(url) { browser.selection.remove(url) }
                        else { browser.selection.insert(url) }
                    } else {
                        browser.path.append(url)
                    }
                } label: {
                    rowLabel(url, isDir: true)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    if isEditing {
                        if browser.selection.contains(url) { browser.selection.remove(url) }
                        else { browser.selection.insert(url) }
                    } else {
                        openDefault(url)
                    }
                } label: { rowLabel(url, isDir: false) }
            }
        }
        .contextMenu {
            if !isDir {
                Button("Buka sebagai Teks") { browser.sheet = .text(url) }
                Button("Buka sebagai Plist") { browser.sheet = .plist(url) }
                Button("Buka sebagai Hex") { browser.sheet = .hex(url) }
                Button("Buka sebagai SQLite") { browser.sheet = .sqlite(url) }
                Button("Pratinjau") { browser.previewURL = url }
            }
            if ["js", "mjs", "txt"].contains(url.pathExtension.lowercased()) {
                Button("Impor sebagai userscript") { importAsUserscript(url) }
            }
            Button("Info") { browser.sheet = .info(url) }
            Button(WQFavorites.contains(url) ? "Hapus dari Favorit" : "Tambah ke Favorit") {
                WQFavorites.toggle(url)
                browser.bump()
            }
            if !isDir {
                ShareLink(item: url) { Text("Bagikan") }
                Button("Duplikat") { duplicate(url) }
                Button("Kompres jadi ZIP") { compress([url]) }
                if ArchiveExtractor.isSupportedArchive(url.lastPathComponent) {
                    Button("Ekstrak di sini") { browser.pendingExtract = url }
                }
            }
            Button("Ubah nama") { browser.renameTarget = url; browser.renameText = url.lastPathComponent }
            Button("Hapus", role: .destructive) { browser.pendingDelete = url }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Hapus", role: .destructive) { browser.pendingDelete = url }
        }
    }

    /// Imports a script file already in My Files as a browser userscript,
    /// without going through the document picker.
    private func importAsUserscript(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let source = BrowserExtension.decodeScript(data),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            browser.notice = "File kosong atau bukan teks."
            return
        }
        browser.notice = store.importUserscript(source: source, fileName: url.lastPathComponent)
    }

    private func rowLabel(_ url: URL, isDir: Bool) -> some View {
        HStack {
            if isEditing {
                Image(systemName: browser.selection.contains(url) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(browser.selection.contains(url) ? Color.accentColor : Color.secondary)
            }
            Image(systemName: isDir ? "folder.fill" : iconFor(url)).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(url.lastPathComponent).lineLimit(1)
                Text(isDir ? "Folder" : fileSize(url)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isDir {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if !isDir {
                Button { browser.previewURL = url } label: { Image(systemName: "eye") }.buttonStyle(.plain)
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.plain)
            }
        }
    }

    private func iconFor(_ url: URL) -> String {
        DownloadCategory.from(fileName: url.lastPathComponent, mime: nil).systemImage
    }

    private func fileSize(_ url: URL) -> String {
        formatBytes(wqFileSize(url))
    }

    private func openDefault(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "plist": browser.sheet = .plist(url)
        case "db", "sqlite", "sqlite3": browser.sheet = .sqlite(url)
        case "txt", "md", "json", "js", "ts", "swift", "xml", "yaml", "yml", "toml", "ini", "css", "html", "csv", "log", "py", "sh", "c", "h", "m", "java", "kt", "go", "rs", "rb", "lua", "sql":
            browser.sheet = .text(url)
        case "zip": browser.pendingExtract = url
        default: browser.previewURL = url
        }
    }

    private func duplicate(_ url: URL) {
        let dest = browser.dedupedURL(in: url.deletingLastPathComponent(), name: url.lastPathComponent)
        try? FileManager.default.copyItem(at: url, to: dest)
        browser.bump()
    }

    private func compress(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let dir = first.deletingLastPathComponent()
        let zipName = (urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Arsip") + ".zip"
        let dest = browser.dedupedURL(in: dir, name: zipName)
        do {
            try WQZip.compress(urls, to: dest)
            browser.bump()
        } catch {
            browser.notice = "Gagal membuat ZIP: \(error.localizedDescription)"
        }
    }

    private func moveHere(_ items: [URL], to dir: URL) {
        var skipped = 0
        for item in items {
            let dest = dir.appendingPathComponent(item.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) { skipped += 1; continue }
            try? FileManager.default.moveItem(at: item, to: dest)
        }
        browser.moveItems = nil
        browser.bump()
        if skipped > 0 { browser.notice = "\(skipped) item dilewati karena namanya sudah ada di folder tujuan (tidak pernah ditimpa)." }
    }
}

// MARK: - Video / gallery grabber
struct VideoGrabberView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    @State private var pageURL = ""
    @State private var results: [GrabbedMedia] = []
    @State private var busy = false
    @State private var message = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Page") {
                    TextField("https://example.com/page-with-video", text: $pageURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Fetch page & find media") { Task { await fetch() } }.disabled(busy || pageURL.isEmpty)
                    Text("Direct video/image links found in the page HTML. Sites using JS players or DRM will usually return nothing here — that is an iOS limitation without yt-dlp, not a silent failure.").font(.caption).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                Section("Found (\(results.count))") {
                    ForEach(results) { media in
                        HStack {
                            Image(systemName: media.kind == .image ? "photo" : "film")
                            VStack(alignment: .leading) {
                                Text(media.label).font(.headline)
                                Text(media.url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("Add") { _ = store.addItem(urlString: media.url) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
            .navigationTitle("Video Grabber")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
    private func fetch() async {
        busy = true; defer { busy = false }
        guard let url = URL(string: pageURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { message = "URL tidak valid."; return }
        do {
            let html = try await VideoGrabber.fetchPage(url: url, settings: store.settings)
            results = VideoGrabber.extract(from: html, baseURL: url)
            message = results.isEmpty ? "No direct media links found in this page's HTML." : ""
        } catch { message = "Gagal: \(error.localizedDescription)" }
    }
}

// MARK: - Torrent add
struct TorrentAddView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    @State private var magnet = ""
    @State private var info: TorrentInfo?
    @State private var peers: [TorrentClient.Peer] = []
    @State private var message = ""
    @State private var busy = false
    @State private var progress: Double = 0
    @State private var showImporter = false
    @State private var selectedFiles: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Add torrent") {
                    TextField("magnet:?xt=urn:btih:…", text: $magnet)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Parse magnet") { parseMagnet() }
                    Button("Import .torrent file…") { showImporter = true }
                    Text("Magnet links without a .torrent file cannot fetch metadata on iOS here (no DHT/magnet metadata exchange). Paste a magnet to see its hash/trackers, or import a .torrent file to download.").font(.caption).foregroundStyle(.secondary)
                }
                if let info {
                    Section("Torrent") {
                        LabeledContent("Name", value: info.name)
                        LabeledContent("Size", value: formatBytes(info.totalLength))
                        LabeledContent("Pieces", value: "\(info.pieces.count) × \(formatBytes(info.pieceLength))")
                        LabeledContent("Tracker", value: info.announce)
                        if let c = info.comment { LabeledContent("Comment", value: c) }
                        LabeledContent("Single file", value: info.isSingleFile ? "Yes" : "No — metadata only")
                    }
                    Section("Files") {
                        ForEach(info.files) { file in
                            Toggle(isOn: Binding(get: { selectedFiles.contains(file.id) || info.files.count == 1 }, set: { on in if on { selectedFiles.insert(file.id) } else { selectedFiles.remove(file.id) } })) {
                                VStack(alignment: .leading) { Text(file.path).lineLimit(2); Text(formatBytes(file.length)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Section("Peers") {
                        Button("Announce to tracker") { Task { await announce() } }.disabled(busy)
                        ForEach(peers.prefix(20), id: \.self) { peer in Text("\(peer.host):\(peer.port)").font(.caption.monospaced()) }
                        if peers.isEmpty { Text("No peers yet — announce first.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Section("Download") {
                        if progress > 0 { ProgressView(value: progress) }
                        Button("Download via peers (experimental, sequential)") { Task { await download() } }.disabled(busy || !info.isSingleFile)
                        if !info.isSingleFile { Text("Multi-file byte download is not supported in this port; file list + metadata above are the honest scope.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("Add Torrent")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    _ = url.startAccessingSecurityScopedResource()
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url) {
                        do {
                            info = try TorrentClient.parseTorrent(data: data)
                            selectedFiles = Set(info?.files.map { $0.id } ?? [])
                            message = ""
                        } catch { message = "Parse gagal: \(error.localizedDescription)" }
                    }
                }
            }
        }
    }

    private func parseMagnet() {
        guard let parsed = TorrentClient.parseMagnet(magnet.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = "Magnet tidak valid / tidak ada info-hash."; return
        }
        message = "Magnet hash: \(parsed.infoHash.map { String(format: "%02x", $0) }.joined()) — metadata fetch (DHT) tidak didukung, import .torrent untuk download."
        if let name = parsed.name {
            info = TorrentInfo(name: name, announce: parsed.trackers.first ?? "", announceList: parsed.trackers, infoHash: parsed.infoHash, pieceLength: 0, pieces: [], totalLength: 0, files: [], isSingleFile: true)
        }
    }

    private func announce() async {
        guard let info else { return }
        busy = true; defer { busy = false }
        var peerID = Data("MDM-IOS-".utf8); peerID.append(Data((0..<12).map { _ in UInt8.random(in: 0...9) + 48 }))
        do { peers = try await TorrentClient.announce(info: info, peerID: peerID, port: 6881, left: info.totalLength) }
        catch { message = "Announce gagal: \(error.localizedDescription)" }
    }

    private func download() async {
        guard let info else { return }
        busy = true; defer { busy = false }
        let dest = store.downloadsDir.appendingPathComponent(info.name)
        do {
            try await TorrentPeerSession.downloadTorrent(info: info, destination: dest, onProgress: { p in Task { @MainActor in self.progress = p } })
            var item = DownloadItem(url: info.announce, fileName: info.name, category: .torrents, state: .completed, totalBytes: info.totalLength, downloadedBytes: info.totalLength, isTorrent: true, torrentName: info.name)
            item.completedAt = Date()
            store.items.insert(item, at: 0); store.save()
            message = "Torrent selesai: \(info.name)"
        } catch { message = "Torrent gagal: \(error.localizedDescription)" }
    }
}
