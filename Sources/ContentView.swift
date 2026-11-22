import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.mdmScale) var scale
    @State private var showingAdd = false
    @State private var showingGrabber = false
    @State private var showingTorrent = false
    @State private var showingSettings = false
    @State private var showingFiles = false
    @State private var showingBrowser = false
    @State private var addURLPreset = ""
    @State private var confirmDelete: DownloadItem?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
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
                    .sheet(isPresented: $showingSettings) { SettingsView() }
                    .sheet(isPresented: $showingFiles) { DownloadedFilesView() }
                    .fullScreenCover(isPresented: $showingBrowser) { BrowserView() }
                    .alert("Hapus download?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
                        Button("Hapus + file", role: .destructive) { if let it = confirmDelete { store.remove(id: it.id, deleteFile: true) } }
                        Button("Hapus dari daftar", role: .destructive) { if let it = confirmDelete { store.remove(id: it.id) } }
                        Button("Batal", role: .cancel) {}
                    }
            }
        }
        .overlay(alignment: .top) { clipboardBanner }
    }

    private var titleForCategory: String {
        store.selectedCategory == .all ? "Mister Download Manager" : store.selectedCategory.rawValue
    }

    private var sidebar: some View {
        List(selection: Binding<DownloadCategory?>(get: { store.selectedCategory }, set: { if let value = $0 { store.selectedCategory = value } })) {
            HStack(spacing: 10) {
                Image("Logo").resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mister Download Manager").font(.headline).lineLimit(1)
                    Text("iOS port · GPL-3.0").font(.caption).foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)
            Section("Categories") {
                ForEach(DownloadCategory.allCases) { cat in
                    Label {
                        HStack { Text(cat.rawValue); Spacer(); Text("\(store.count(for: cat))").foregroundStyle(.secondary).font(.caption) }
                    } icon: { Image(systemName: cat.systemImage) }
                    .tag(cat)
                }
            }
            Section("Tools") {
                Button { showingBrowser = true } label: { Label("Browser", systemImage: "globe") }
                Button { showingGrabber = true } label: { Label("Video / Gallery Grabber", systemImage: "play.rectangle.on.rectangle") }
                Button { showingTorrent = true } label: { Label("Add Torrent", systemImage: "magnet") }
                Button { showingFiles = true } label: { Label("Downloaded Files", systemImage: "folder") }
                Button { showingAdd = true } label: { Label("Add URL", systemImage: "link.badge.plus") }
            }
            Section("App") {
                Button { showingSettings = true } label: { Label("Options / Settings", systemImage: "gearshape") }
                LabeledContent("Scheduler", value: store.settings.schedulerEnabled ? (store.schedulerAllowsNow() ? "Active window" : "Outside window") : "Off")
                if let addr = store.remoteAddress {
                    LabeledContent("Remote", value: addr)
                }
            }
            Section("About") {
                Text("iOS port of Mister Download Manager (GPL-3.0). Desktop-only features are listed in Settings → About — not hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("MDM")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { addURLPreset = ""; showingAdd = true } label: { Label("Add URL…", systemImage: "link") }
                Button { showingTorrent = true } label: { Label("Add Torrent…", systemImage: "magnet") }
                Button { showingGrabber = true } label: { Label("Grab Video from Page…", systemImage: "play.rectangle") }
                if let clip = UIPasteboard.general.string, clip.hasPrefix("http") {
                    Button { addURLPreset = clip; showingAdd = true } label: { Label("Add from Clipboard", systemImage: "doc.on.clipboard") }
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
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
        }
    }

    private var downloadList: some View {
        List {
            if store.filteredItems().isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No downloads").font(.headline)
                    Text("Tap + to add a link, a torrent, or grab a video from a page.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding()
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: item.category.systemImage).foregroundStyle(.tint)
                Text(item.fileName).lineLimit(1).font(.headline)
                Spacer()
                Text(item.state.label).font(.caption).foregroundStyle(stateColor)
            }
            ProgressView(value: item.progress)
                .tint(item.state == .failed ? .red : nil)
            if !item.segments.isEmpty && item.state == .downloading {
                SegmentBarView(segments: item.segments)
            }
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
        .padding(.vertical, 4)
    }
    private var stateColor: Color {
        switch item.state {
        case .completed: return .green
        case .failed: return .red
        case .downloading: return .blue
        case .paused: return .orange
        case .queued: return .secondary
        case .verifying: return .purple
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
                    Stepper("Connections: \(connections)", value: $connections, in: 1...60)
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
            do { finalURL = try await DebridClient.unrestrict(finalURL, service: service, settings: store.settings) }
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
    }

    private func extract() {
        do {
            let dest = store.downloadsDir.appendingPathComponent((item.fileName as NSString).deletingPathExtension)
            extracted = try ArchiveExtractor.extract(zipURL: store.downloadsDir.appendingPathComponent(item.fileName), to: dest)
            extractMessage = "Extracted \(extracted.count) file(s) to \(dest.lastPathComponent)."
        } catch { extractMessage = "Extract gagal: \(error.localizedDescription)" }
    }
}
