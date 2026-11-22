import SwiftUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - Settings
struct SettingsView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    Stepper("Max connections per download: \(store.settings.maxConnections)", value: $store.settings.maxConnections, in: 1...16)
                    Stepper("Max concurrent downloads: \(store.settings.maxConcurrentDownloads)", value: $store.settings.maxConcurrentDownloads, in: 1...5)
                    Stepper("Speed limit: \(store.settings.speedLimitKBps == 0 ? "Unlimited" : "\(store.settings.speedLimitKBps) KB/s")", value: $store.settings.speedLimitKBps, in: 0...100000, step: 100)
                    Toggle("Wi-Fi only (kill-switch approximation)", isOn: $store.settings.wifiOnly)
                    Toggle("Start downloads paused", isOn: $store.settings.startPaused)
                    Toggle("Auto-resume on launch", isOn: $store.settings.autoResumeOnLaunch)
                    TextField("User-Agent", text: $store.settings.userAgent)
                }
                Section("Queue & Scheduler") {
                    Toggle("Queue enabled", isOn: $store.settings.queueEnabled)
                    Toggle("Scheduler enabled", isOn: $store.settings.schedulerEnabled)
                    Stepper("Start: \(store.settings.schedulerStartHour):\(String(format: "%02d", store.settings.schedulerStartMinute))", value: $store.settings.schedulerStartHour, in: 0...23)
                    Stepper("Stop: \(store.settings.schedulerStopHour):\(String(format: "%02d", store.settings.schedulerStopMinute))", value: $store.settings.schedulerStopHour, in: 0...23)
                    Text("iOS cannot wake the phone or shut it down like the desktop scheduler. The window only gates starting/pausing while the app runs, and background downloads are limited by iOS.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Debrid — your own keys") {
                    SecureField("Real-Debrid API key", text: $store.settings.realDebridKey)
                    SecureField("AllDebrid API key", text: $store.settings.allDebridKey)
                    SecureField("Premiumize API key", text: $store.settings.premiumizeKey)
                    SecureField("TorBox token", text: $store.settings.torboxKey)
                    SecureField("Mega-Debrid token", text: $store.settings.megaDebridKey)
                    Text("Keys stay in this app's settings file on this device. Debrid is experimental in the desktop app too.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Proxy & DNS") {
                    Toggle("Use proxy", isOn: $store.settings.proxyEnabled)
                    Picker("Proxy type", selection: $store.settings.proxyType) { Text("HTTP").tag("HTTP"); Text("SOCKS").tag("SOCKS") }
                    TextField("Proxy host", text: $store.settings.proxyHost)
                    Stepper("Proxy port: \(store.settings.proxyPort)", value: $store.settings.proxyPort, in: 1...65535)
                    TextField("Custom DNS (stored only)", text: $store.settings.customDNS)
                    Text("iOS URLSession cannot override DNS per app, so a custom DNS value is stored for reference only and does not change resolution.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Appearance, Language & Scale") {
                    Picker("Theme", selection: $store.settings.themeName) {
                        ForEach(ThemeName.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Language", selection: $store.settings.language) {
                        Text("English").tag("en"); Text("Bahasa Indonesia").tag("id"); Text("العربية (RTL)").tag("ar"); Text("Français").tag("fr"); Text("Deutsch").tag("de"); Text("日本語").tag("ja")
                    }
                    Text("Full 86-language catalogues from the desktop app are not ported; the UI strings in this build are English with Indonesian notes in key places. Language choice is stored and applied to new strings as they are translated.").font(.caption).foregroundStyle(.secondary)
                    HStack { Text("Interface scale"); Slider(value: $store.settings.interfaceScale, in: 0.8...2.0, step: 0.1); Text("\(Int(store.settings.interfaceScale * 100))%") }
                }
                Section("Notifications & Clipboard") {
                    Toggle("Download notifications", isOn: $store.settings.notificationsEnabled)
                    Toggle("Watch clipboard for links", isOn: $store.settings.clipboardMonitor)
                }
                Section("Remote control (LAN)") {
                    Toggle("Enable remote control", isOn: $store.settings.remoteControlEnabled)
                    Stepper("Port: \(store.settings.remotePort)", value: $store.settings.remotePort, in: 1024...65535)
                    if let addr = store.remoteAddress { LabeledContent("Address", value: addr) }
                    Text("Plain HTTP on trusted home Wi-Fi only, while the app is in the foreground. The desktop remote uses HTTPS pairing; that pairing flow is not ported.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Browser & AdBlock") {
                    Toggle("Built-in AdBlock (automatic)", isOn: $store.browserSettings.adBlockEnabled)
                    Toggle("Custom AdBlock (your URL filters)", isOn: $store.browserSettings.customAdBlockEnabled)
                    Toggle("Desktop site", isOn: $store.browserSettings.desktopMode)
                    Toggle("Putar di background (termasuk YouTube)", isOn: $store.browserSettings.backgroundPlayback)
                    Toggle("Picture in Picture", isOn: $store.browserSettings.pictureInPicture)
                    Toggle("Blokir popup", isOn: $store.browserSettings.blockPopups)
                    Toggle("Tampilkan pratinjau link (tekan lama)", isOn: $store.browserSettings.linkPreview)
                    Toggle("Deteksi alamat (buka di Google Maps)", isOn: $store.browserSettings.detectAddresses)
                    Toggle("Web Inspector (periksa dari Safari di Mac)", isOn: $store.browserSettings.webInspector)
                    TextField("Home page", text: $store.browserSettings.homePage)
                        .autocapitalization(.none).autocorrectionDisabled()
                    Text("The in-app browser (Tools → Browser) runs both AdBlock lists together and captures downloads straight into the queue. Chrome extensions cannot run on iOS — the browser's extensions are JavaScript userscripts, managed in the browser's shield panel.").font(.caption).foregroundStyle(.secondary)
                }
                Section("About & honest limits") {
                    Text("Mister Download Manager — iOS port. Original: github.com/anefzaoui/misterdownloadmanager, GPL-3.0, Rust/egui desktop app for Windows/Mac/Linux. This SwiftUI reimplementation keeps the download engine ideas (segmentation, resume, categories, queues, scheduler window, debrid, video grabber, torrent metadata, remote control) within iOS sandbox limits.")
                    Text("Not ported: Chrome extensions and the desktop browser native-messaging host (the in-app browser captures downloads itself instead), system tray, wake/shutdown, yt-dlp/ffmpeg video processing, 7z/RAR via 7-Zip, MCP server, CLI switches, DHT/uTP/UPnP torrenting and background seeding, 86 languages, screen-reader-perfect desktop menus. Nothing here pretends those work.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Original repository", destination: URL(string: "https://github.com/anefzaoui/misterdownloadmanager")!)
                    Link("License: GPL-3.0", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                }
            }
            .navigationTitle("Options")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { store.save(); dismiss() } } }
            .onReceive(store.$settings.dropFirst()) { _ in store.save() }
            .onReceive(store.$browserSettings.dropFirst()) { _ in store.saveBrowserSettings() }
        }
    }
}

// MARK: - Downloaded files
struct DownloadedFilesView: View {
    @EnvironmentObject var store: DownloadStore
    @State private var previewURL: URL?
    @State private var renameTarget: URL?
    @State private var renameText = ""
    var body: some View {
        NavigationStack {
            List {
                if store.downloadedFiles().isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "folder").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No files yet").font(.headline)
                        Text("Completed downloads appear here.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding()
                }
                ForEach(store.downloadedFiles(), id: \.self) { url in
                    HStack {
                        Image(systemName: iconFor(url)).foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(fileSize(url)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { previewURL = url } label: { Image(systemName: "eye") }
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                    .contextMenu {
                        Button("Rename") { renameTarget = url; renameText = url.lastPathComponent }
                        Button("Delete", role: .destructive) { store.deleteDownloadedFile(url) }
                    }
                }
            }
            .navigationTitle("Downloaded Files")
            .quickLookPreview($previewURL)
            .alert("Rename file", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("New name", text: $renameText)
                Button("Rename") {
                    if let old = renameTarget, !renameText.isEmpty {
                        try? FileManager.default.moveItem(at: old, to: old.deletingLastPathComponent().appendingPathComponent(renameText))
                    }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
        }
    }
    private func iconFor(_ url: URL) -> String {
        DownloadCategory.from(fileName: url.lastPathComponent, mime: nil).systemImage
    }
    private func fileSize(_ url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return formatBytes(size)
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
