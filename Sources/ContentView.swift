import SwiftUI
import UniformTypeIdentifiers

/// Bottom tab bar (like the reference browser app): Downloads,
/// Browser, AI chat, My Files, Tools. Settings and API Tester live
/// inside Tools (Paket B, Fase 4).
enum AppTab: Hashable {
    case downloads, browser, ai, files, tools
}

struct ContentView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.mdmScale) var scale
    @State private var selectedTab: AppTab = .downloads
    @State private var showingAdd = false
    @State private var showingGrabber = false
    @State private var showingTorrent = false
    @State private var showingSettings = false
    @State private var addURLPreset = ""
    @State private var confirmDelete: DownloadItem?

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                // iPad: sidebar navigation (Paket B). The detail column
                // shows the same root views as the iPhone tabs.
                NavigationSplitView {
                    List(selection: sidebarSelection) {
                        ForEach([AppTab.downloads, .browser, .ai, .files, .tools], id: \.self) { tab in
                            Label(sidebarLabel(for: tab), systemImage: sidebarIcon(for: tab)).tag(tab)
                        }
                    }
                    .navigationTitle("Mister Download Manager")
                } detail: {
                    detailView(for: selectedTab)
                }
            } else {
                // The system tab bar: on iOS 26 it renders as the floating
                // liquid-glass pill, and long-press-drag scrubs the glass
                // selection bubble along it (the effect in the Telegram
                // video). The custom pill could not morph like that, and the
                // "ghost capsule" was only ever the hidden system bar drawing
                // behind it — with the bar visible and holding the tab items
                // there is no ghost, and tab content is inset above it natively.
                TabView(selection: $selectedTab) {
                    detailView(for: .downloads)
                        .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                        .tag(AppTab.downloads)
                    detailView(for: .browser)
                        .tabItem { Label("Browser", systemImage: "globe") }
                        .tag(AppTab.browser)
                    detailView(for: .ai)
                        .tabItem { Label("AI", systemImage: "sparkles") }
                        .tag(AppTab.ai)
                    detailView(for: .files)
                        .tabItem { Label("My Files", systemImage: "folder") }
                        .tag(AppTab.files)
                    detailView(for: .tools)
                        .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                        .tag(AppTab.tools)
                }
            }
        }
        .onChange(of: store.aiHandoff) { handoff in
            if handoff != nil { selectedTab = .ai }
        }
        .overlay(alignment: .top) { clipboardBanner }
        .alert("Userscript diimpor", isPresented: Binding(get: { store.lastImportMessage != nil }, set: { if !$0 { store.lastImportMessage = nil } })) {
            Button("OK", role: .cancel) { store.lastImportMessage = nil }
        } message: {
            Text(store.lastImportMessage ?? "")
        }
    }

    /// One source for the five root views, shared by the iPhone tab bar
    /// and the iPad sidebar detail column.
    @ViewBuilder
    private func detailView(for tab: AppTab) -> some View {
        switch tab {
        case .downloads:
            NavigationStack {
                downloadList
                    .navigationTitle(titleForCategory)
                    .toolbar { toolbarContent }
                    .navigationDestination(for: UUID.self) { id in
                        if let item = store.item(id) { DownloadDetailView(item: item) }
                    }
                    .sheet(isPresented: $showingAdd) { AddURLView(presetURL: addURLPreset) }
                    .sheet(isPresented: $showingGrabber) { VideoGrabberView() }
                    .sheet(isPresented: $showingTorrent) { TorrentAddView() }
                    .sheet(isPresented: $showingSettings) { SettingsView(showsDoneButton: true) }
                    .alert("Hapus download?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
                        Button("Hapus + file", role: .destructive) { if let it = confirmDelete { store.remove(id: it.id, deleteFile: true) } }
                        Button("Hapus dari daftar", role: .destructive) { if let it = confirmDelete { store.remove(id: it.id) } }
                        Button("Batal", role: .cancel) {}
                    }
            }
        case .browser:
            BrowserView(onExitToDownloads: { selectedTab = .downloads })
        case .ai:
            AIChatView()
        case .files:
            DownloadedFilesView()
        case .tools:
            NavigationStack { ToolsHubView() }
        }
    }

    private var sidebarSelection: Binding<AppTab?> {
        Binding(get: { selectedTab }, set: { if let tab = $0 { selectedTab = tab } })
    }

    private func sidebarLabel(for tab: AppTab) -> String {
        switch tab {
        case .downloads: return "Downloads"
        case .browser: return "Browser"
        case .ai: return "AI"
        case .files: return "My Files"
        case .tools: return "Tools"
        }
    }

    private func sidebarIcon(for tab: AppTab) -> String {
        switch tab {
        case .downloads: return "arrow.down.circle"
        case .browser: return "globe"
        case .ai: return "sparkles"
        case .files: return "folder"
        case .tools: return "wrench.and.screwdriver"
        }
    }

    private var titleForCategory: String {
        store.selectedCategory == .all ? "Mister Download Manager" : store.selectedCategory.rawValue
    }

    private var activeDownloadCount: Int { store.items.filter { $0.state == .downloading }.count }
    private var aggregateSpeed: Double { store.items.filter { $0.state == .downloading }.reduce(0) { $0 + $1.speedBytesPerSec } }
    private var totalDownloadedBytes: Int64 { store.items.reduce(0) { $0 + $1.downloadedBytes } }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { addURLPreset = ""; showingAdd = true } label: { Label("Add URL…", systemImage: "link") }
                Button { showingTorrent = true } label: { Label("Add Torrent…", systemImage: "magnet") }
                Button { showingGrabber = true } label: { Label("Grab Video from Page…", systemImage: "play.rectangle") }
                if let clip = store.lastClipboardURL {
                    Button { addURLPreset = clip; store.pendingClipboardURL = nil; showingAdd = true } label: { Label("Add from Clipboard", systemImage: "doc.on.clipboard") }
                }
            } label: { Image(systemName: "plus") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { store.startAll() } label: { Image(systemName: "play.fill") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { store.pauseAll() } label: { Image(systemName: "pause.fill") }
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Kategori", selection: Binding(get: { store.selectedCategory }, set: { store.selectedCategory = $0 })) {
                    ForEach(DownloadCategory.allCases) { cat in
                        Label("\(cat.rawValue) (\(store.count(for: cat)))", systemImage: cat.systemImage).tag(cat)
                    }
                }
            } label: {
                Label(store.selectedCategory.rawValue, systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
        }
    }

    private var downloadList: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    MDMStatCard(icon: "arrow.down.circle", label: "Aktif", value: "\(activeDownloadCount)", accent: .mdmAccent)
                    MDMStatCard(icon: "speedometer", label: "Kecepatan", value: formatSpeed(aggregateSpeed), accent: .mdmAccent2)
                    MDMStatCard(icon: "archivebox", label: "Total", value: formatBytes(totalDownloadedBytes), accent: .mdmSuccess)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
            }
            if store.filteredItems().isEmpty {
                MDMEmptyState(icon: "arrow.down.circle", title: "No downloads", message: "Tap + to add a link, a torrent, or grab a video from a page.")
            }
            ForEach(store.filteredItems()) { item in
                NavigationLink(value: item.id) {
                    DownloadRowView(item: item)
                }
                .contextMenu {
                    if item.state == .downloading { Button("Pause") { store.pause(id: item.id) } }
                    if item.state == .paused || item.state == .failed || item.state == .queued { Button("Resume / Start") { store.start(id: item.id) } }
                    Button("Retry from scratch") { store.retry(id: item.id) }
                    Button("Delete", role: .destructive) { confirmDelete = item }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { confirmDelete = item } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions(edge: .leading) {
                    if item.state == .downloading {
                        Button { store.pause(id: item.id) } label: { Label("Pause", systemImage: "pause.fill") }.tint(.orange)
                    } else {
                        Button { store.start(id: item.id) } label: { Label("Start", systemImage: "play.fill") }.tint(.green)
                    }
                }
            }
        }
        .searchable(text: $store.searchText, prompt: "Search downloads")
        .refreshable { store.checkClipboard() }
        .scrollContentBackground(.hidden)
        .background(Color.mdmBackground)
    }

    @ViewBuilder
    private var clipboardBanner: some View {
        if let url = store.pendingClipboardURL {
            HStack {
                Image(systemName: "doc.on.clipboard")
                Text(url).lineLimit(1).font(.caption)
                Button("Add") { addURLPreset = url; store.pendingClipboardURL = nil; showingAdd = true }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button { store.pendingClipboardURL = nil } label: { Image(systemName: "xmark") }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
            .shadow(radius: 4)
        }
    }
}

struct DownloadRowView: View {
    var item: DownloadItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(item.category.mdmTint.opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: item.category.systemImage)
                    .foregroundStyle(item.category.mdmTint)
                    .font(.system(size: 18, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.fileName).lineLimit(1).font(.headline)
                    Spacer()
                    MDMStatusBadge(text: item.state.label, tone: statusTone)
                }
                MDMProgressBar(progress: item.progress, segments: item.segments, totalBytes: item.totalBytes, failed: item.state == .failed)
                HStack {
                    Text(item.totalBytes.map { formatBytes($0) } ?? "Unknown size").font(.caption).foregroundStyle(.secondary)
                    if item.state == .downloading {
                        Text(formatSpeed(item.speedBytesPerSec)).font(.caption).foregroundStyle(.secondary)
                        Text("ETA \(formatETA(item.etaSeconds))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int(item.progress * 100))%").font(.caption.monospacedDigit())
                }
                if let err = item.errorMessage, item.state == .failed {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                if item.checksumVerified == false {
                    Text("Checksum mismatch — file may be corrupt.").font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }
    private var statusTone: MDMStatusTone {
        switch item.state {
        case .completed: return .success
        case .failed: return .error
        case .downloading: return .accent
        case .paused: return .warning
        case .queued: return .muted
        case .verifying: return .teal
        }
    }
}

struct SegmentBarView: View {
    var segments: [SegmentState]
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments.indices, id: \.self) { i in
                    let seg = segments[i]
                    let total = max(1, seg.end - seg.start + 1)
                    let frac = CGFloat(seg.downloaded) / CGFloat(total)
                    Rectangle()
                        .fill(frac >= 1 ? Color.green : Color.accentColor)
                        .frame(width: max(2, (geo.size.width / CGFloat(segments.count)) * 0.9))
                        .opacity(0.35 + 0.65 * frac)
                }
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct AddURLView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    var presetURL: String = ""
    @State private var url = ""
    @State private var fileName = ""
    @State private var category: DownloadCategory = .other
    @State private var connections = 8
    @State private var referer = ""
    @State private var checksumType = "None"
    @State private var checksumValue = ""
    @State private var debridService: DebridService?
    @State private var busy = false
    @State private var message = ""
    @State private var probed: ProbeResult?

    var body: some View {
        NavigationStack {
            Form {
                Section("Link") {
                    TextField("https://example.com/file.zip", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: url) { _ in probed = nil }
                    Button("Probe link (size / resume)") { Task { await probe() } }
                        .disabled(busy || url.isEmpty)
                    if let p = probed {
                        LabeledContent("Size", value: p.totalBytes.map { formatBytes($0) } ?? "Unknown")
                        LabeledContent("Resume", value: p.acceptRanges ? "Supported" : "Not supported")
                        if let mime = p.mimeType { LabeledContent("Type", value: mime) }
                    }
                    TextField("Save as (optional)", text: $fileName)
                    Picker("Category", selection: $category) {
                        ForEach(DownloadCategory.allCases.filter { $0 != .all }) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Text("Connections")
                        Slider(value: Binding(get: { Double(connections) }, set: { connections = Int($0) }), in: 1...60, step: 1)
                        Text("\(connections)").frame(width: 28, alignment: .trailing)
                    }
                    TextField("Referer (optional)", text: $referer)
                }
                Section("Checksum (optional)") {
                    Picker("Type", selection: $checksumType) {
                        Text("None").tag("None"); Text("MD5").tag("MD5"); Text("SHA1").tag("SHA1"); Text("SHA256").tag("SHA256")
                    }
                    TextField("Expected hash", text: $checksumValue).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Debrid (optional)") {
                    Picker("Service", selection: $debridService) {
                        Text("None").tag(nil as DebridService?)
                        ForEach(DebridService.allCases) { Text($0.rawValue).tag($0 as DebridService?) }
                    }
                    Text("Unrestricts a file-host link with your own key from Settings → Debrid.").font(.caption).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                if url.lowercased().contains(".m3u8") {
                    Section("HLS") {
                        Text("This is an .m3u8 playlist. Use “Download HLS” to fetch its segments into one file (unencrypted playlists only).")
                        Button("Download HLS") { Task { await downloadHLS() } }.disabled(busy)
                    }
                }
            }
            .navigationTitle("Add Download")
            .scrollContentBackground(.hidden)
            .background(Color.mdmBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }.disabled(busy || url.isEmpty)
                }
            }
            .onAppear {
                url = presetURL
                connections = store.settings.maxConnections
                if let clip = UIPasteboard.general.string, url.isEmpty, clip.hasPrefix("http") { url = clip }
            }
        }
    }

    private func probe() async {
        busy = true; defer { busy = false }
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { message = "URL tidak valid."; return }
        do {
            let p = try await DownloadEngine.probe(url: u, settings: store.settings, referer: referer.isEmpty ? nil : referer)
            probed = p
            if fileName.isEmpty, let fn = p.fileName { fileName = fn }
            if let mime = p.mimeType { category = DownloadCategory.from(fileName: fileName.isEmpty ? u.lastPathComponent : fileName, mime: mime) }
            message = ""
        } catch { message = "Probe gagal: \(error.localizedDescription)" }
    }

    private func add() async {
        busy = true; defer { busy = false }
        var finalURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let service = debridService {
            do { finalURL = try await DebridClient.unrestrict(finalURL, service: service) }
            catch { message = "Debrid gagal: \(error.localizedDescription)"; busy = false; return }
        }
        let name = fileName.isEmpty ? nil : fileName
        if store.addItem(urlString: finalURL, fileName: name, category: category, connections: connections, checksumType: checksumType == "None" ? nil : checksumType, checksumValue: checksumValue.isEmpty ? nil : checksumValue, referer: referer.isEmpty ? nil : referer) != nil {
            dismiss()
        } else { message = store.lastError ?? "Gagal menambah download." }
    }

    private func downloadHLS() async {
        busy = true; defer { busy = false }
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let name = fileName.isEmpty ? "stream.ts" : fileName
        let dest = store.downloadsDir.appendingPathComponent(name)
        do {
            try await VideoGrabber.downloadHLS(playlistURL: u, destination: dest, settings: store.settings, onProgress: nil)
            var item = DownloadItem(url: url, fileName: name, category: .video, state: .completed, totalBytes: (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64), downloadedBytes: (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0)
            item.completedAt = Date()
            store.items.insert(item, at: 0); store.save()
            dismiss()
        } catch { message = "HLS gagal: \(error.localizedDescription)" }
    }
}

struct DownloadDetailView: View {
    @EnvironmentObject var store: DownloadStore
    var item: DownloadItem
    @State private var extracted: [URL] = []
    @State private var extractMessage = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    MDMStatusBadge(text: item.state.label, tone: detailStatusTone)
                    Spacer()
                    Text("\(Int(item.progress * 100))%").font(.caption.monospacedDigit())
                }
                MDMProgressBar(progress: item.progress, segments: item.segments, totalBytes: item.totalBytes, failed: item.state == .failed)
            }
            Section("File") {
                LabeledContent("Name", value: item.fileName)
                LabeledContent("URL", value: item.url)
                LabeledContent("Category", value: item.category.rawValue)
                LabeledContent("Size", value: item.totalBytes.map { formatBytes($0) } ?? "Unknown")
                LabeledContent("Downloaded", value: formatBytes(item.downloadedBytes))
                LabeledContent("Speed", value: formatSpeed(item.speedBytesPerSec))
                LabeledContent("ETA", value: formatETA(item.etaSeconds))
                LabeledContent("Connections", value: "\(item.connections)")
                LabeledContent("Resume", value: item.resumeSupported ? "Supported" : "Unknown / not supported")
                if let mime = item.mimeType { LabeledContent("MIME", value: mime) }
                if let site = item.site { LabeledContent("Server", value: site) }
                if let type = item.checksumType, let value = item.checksumValue {
                    LabeledContent("Checksum", value: "\(type): \(value)")
                    LabeledContent("Verified", value: item.checksumVerified.map { $0 ? "Yes" : "NO — mismatch" } ?? "Not checked")
                }
                if let err = item.errorMessage { Text(err).foregroundStyle(.red).font(.caption) }
            }
            if !item.segments.isEmpty {
                Section("Connections") {
                    SegmentBarView(segments: item.segments).frame(height: 10)
                    ForEach(item.segments.indices, id: \.self) { i in
                        let seg = item.segments[i]
                        LabeledContent("Connection \(i + 1)", value: "\(formatBytes(seg.downloaded)) / \(formatBytes(seg.end - seg.start + 1))")
                    }
                }
            }
            Section("Actions") {
                if item.state == .downloading { Button("Pause") { store.pause(id: item.id) } }
                if item.state != .downloading && item.state != .completed { Button("Start / Resume") { store.start(id: item.id) } }
                Button("Retry from scratch") { store.retry(id: item.id) }
                if item.state == .completed {
                    ShareLink(item: store.downloadsDir.appendingPathComponent(item.fileName)) { Label("Share file", systemImage: "square.and.arrow.up") }
                    if ArchiveExtractor.isSupportedArchive(item.fileName) {
                        Button("Extract ZIP here") { extract() }
                    }
                    if (item.fileName as NSString).pathExtension.lowercased() == "rar" || (item.fileName as NSString).pathExtension.lowercased() == "7z" {
                        Text("7z / RAR extraction needs the 7-Zip helper on desktop and is not available on iOS.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !extractMessage.isEmpty { Text(extractMessage).font(.caption) }
                ForEach(extracted, id: \.self) { url in Text(url.lastPathComponent).font(.caption) }
                Button("Delete download", role: .destructive) { store.remove(id: item.id) }
            }
            if item.isTorrent {
                Section("Torrent") {
                    Text("Torrent downloads in this port are experimental: open Add Torrent and pick a .torrent file for peer download. Magnet placeholders do not download by themselves.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(item.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color.mdmBackground)
    }

    private var detailStatusTone: MDMStatusTone {
        switch item.state {
        case .completed: return .success
        case .failed: return .error
        case .downloading: return .accent
        case .paused: return .warning
        case .queued: return .muted
        case .verifying: return .teal
        }
    }

    private func extract() {
        do {
            let dest = store.downloadsDir.appendingPathComponent((item.fileName as NSString).deletingPathExtension)
            extracted = try ArchiveExtractor.extract(zipURL: store.downloadsDir.appendingPathComponent(item.fileName), to: dest)
            extractMessage = "Extracted \(extracted.count) file(s) to \(dest.lastPathComponent)."
        } catch { extractMessage = "Extract gagal: \(error.localizedDescription)" }
    }
}
