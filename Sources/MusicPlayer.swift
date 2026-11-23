import SwiftUI
import AVFoundation
import MediaPlayer

// MARK: - Built-in music player (Spotify-style)
//
// Honest scope, stated in the UI and README too:
// - Search + 30-second previews come from the free iTunes Search API
//   (no key, no account). Full-track streaming needs a licensed
//   service, which this app does not have.
// - Files the user already downloaded (MP3/M4A/FLAC/...) play in full
//   from the device, with the same player and lyrics.
// - Lyrics come from lrclib (free, no key): synced LRC when available,
//   plain text otherwise. Not every track has lyrics.
// - "YouTube Music" is a web search shortcut: YouTube Music has no
//   official audio-streaming API, and extracting its streams would
//   break its terms, so the app opens the search in the web instead
//   of pretending to stream it natively.

struct MusicTrack: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var streamURL: URL?
    var duration: TimeInterval
    var isLocal: Bool

    var durationLabel: String {
        guard duration > 0 else { return "—" }
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var youTubeMusicSearchURL: URL? {
        var comps = URLComponents(string: "https://music.youtube.com/search")
        comps?.queryItems = [URLQueryItem(name: "q", value: "\(title) \(artist)")]
        return comps?.url
    }
}

struct LyricsLine: Identifiable, Hashable {
    var id = UUID()
    var time: TimeInterval
    var text: String
}

struct LyricsResult {
    var lines: [LyricsLine]
    var plainText: String?
    var instrumental: Bool
}

enum LyricsState {
    case idle
    case loading
    case loaded(LyricsResult)
    case unavailable
}

// MARK: - Lyrics (lrclib, free, no key)

enum LyricsClient {
    private struct Response: Decodable {
        var plainLyrics: String?
        var syncedLyrics: String?
        var instrumental: Bool?
    }

    static func fetchLyrics(for track: MusicTrack) async -> LyricsResult? {
        // Direct lookup first (needs duration in whole seconds).
        var comps = URLComponents(string: "https://lrclib.net/api/get")
        comps?.queryItems = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(track.duration))),
        ]
        if let url = comps?.url, let result = await fetch(from: url) { return result }
        // Fallback: search, prefer an entry that has synced lyrics.
        var search = URLComponents(string: "https://lrclib.net/api/search")
        search?.queryItems = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title),
        ]
        guard let url = search?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode([Response].self, from: data) else { return nil }
        let best = list.first { ($0.syncedLyrics ?? "").contains("[") } ?? list.first
        guard let chosen = best else { return nil }
        return makeResult(from: chosen)
    }

    private static func fetch(from url: URL) async -> LyricsResult? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return makeResult(from: decoded)
    }

    private static func makeResult(from response: Response) -> LyricsResult {
        let lines = parseLRC(response.syncedLyrics ?? "")
        return LyricsResult(lines: lines, plainText: response.plainLyrics, instrumental: response.instrumental ?? false)
    }

    /// Parses `[mm:ss.xx] text` lines (several timestamps per line are
    /// allowed). Metadata tags like `[ti:...]` never match the pattern.
    static func parseLRC(_ text: String) -> [LyricsLine] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#) else { return [] }
        var lines: [LyricsLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let lyricText = ns.substring(from: last.range.upperBound).trimmingCharacters(in: .whitespaces)
            guard !lyricText.isEmpty else { continue }
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                lines.append(LyricsLine(time: minutes * 60 + seconds, text: lyricText))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}

// MARK: - Search (iTunes Search API, free, no key)

enum ITunesSearch {
    private struct ITunesResponse: Decodable {
        var results: [ITunesSong]
    }
    private struct ITunesSong: Decodable {
        var trackName: String?
        var artistName: String?
        var collectionName: String?
        var artworkUrl100: String?
        var previewUrl: String?
        var trackTimeMillis: Int?
    }

    static func search(_ query: String) async throws -> [MusicTrack] {
        var comps = URLComponents(string: "https://itunes.apple.com/search")
        comps?.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "country", value: "ID"),
        ]
        guard let url = comps?.url else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let decoded = try JSONDecoder().decode(ITunesResponse.self, from: data)
        return decoded.results.compactMap { song in
            guard let title = song.trackName, let preview = song.previewUrl,
                  let stream = URL(string: preview) else { return nil }
            let artwork = song.artworkUrl100?
                .replacingOccurrences(of: "100x100", with: "600x600")
                .flatMap { URL(string: $0) }
            return MusicTrack(
                id: "itunes:\(title)-\(song.artistName ?? "")-\(song.collectionName ?? "")",
                title: title,
                artist: song.artistName ?? "Artis tidak dikenal",
                album: song.collectionName ?? "",
                artworkURL: artwork,
                streamURL: stream,
                duration: TimeInterval(song.trackTimeMillis ?? 30_000) / 1000,
                isLocal: false
            )
        }
    }
}

// MARK: - Player

@MainActor
final class MusicPlayer: ObservableObject {
    @Published var queue: [MusicTrack] = []
    @Published var currentIndex: Int?
    @Published var isPlaying = false
    @Published var progress: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var lyricsState: LyricsState = .idle
    @Published var liked: [MusicTrack] = []

    private let player = AVPlayer()
    private var lyricsTask: Task<Void, Never>?
    private var artworkCache: [String: UIImage] = [:]

    var current: MusicTrack? {
        guard let idx = currentIndex, queue.indices.contains(idx) else { return nil }
        return queue[idx]
    }

    var currentLyricIndex: Int? {
        guard case .loaded(let result) = lyricsState, !result.lines.isEmpty else { return nil }
        var found: Int?
        for (i, line) in result.lines.enumerated() where line.time <= progress { found = i }
        return found
    }

    private static let likedKey = "mdm-music-liked-v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.likedKey),
           let saved = try? JSONDecoder().decode([MusicTrack].self, from: data) {
            liked = saved
        }
        configureAudioSession()
        setupRemoteCommands()
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progress = time.seconds
                if let itemDuration = self.player.currentItem?.duration, itemDuration.isNumeric {
                    self.duration = itemDuration.seconds
                }
                self.updateNowPlaying()
            }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleTrackEnded() }
        }
    }

    func isLiked(_ track: MusicTrack) -> Bool { liked.contains { $0.id == track.id } }

    func toggleLike(_ track: MusicTrack) {
        if let idx = liked.firstIndex(where: { $0.id == track.id }) {
            liked.remove(at: idx)
        } else {
            liked.append(track)
        }
        if let data = try? JSONEncoder().encode(liked) {
            UserDefaults.standard.set(data, forKey: Self.likedKey)
        }
    }

    func play(tracks: [MusicTrack], index: Int) {
        guard tracks.indices.contains(index), let stream = tracks[index].streamURL else { return }
        queue = tracks
        currentIndex = index
        progress = 0
        duration = tracks[index].duration
        player.replaceCurrentItem(with: AVPlayerItem(url: stream))
        player.play()
        isPlaying = true
        fetchLyrics()
        updateNowPlaying()
    }

    func togglePlay() {
        guard current != nil else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        updateNowPlaying()
    }

    func next() {
        guard let idx = currentIndex, idx + 1 < queue.count else { return }
        play(tracks: queue, index: idx + 1)
    }

    func previous() {
        guard let idx = currentIndex else { return }
        if progress > 3 { seek(to: 0); return }
        guard idx > 0 else { seek(to: 0); return }
        play(tracks: queue, index: idx - 1)
    }

    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        progress = seconds
        updateNowPlaying()
    }

    func seekToLyric(_ line: LyricsLine) { seek(to: line.time) }

    private func handleTrackEnded() {
        if let idx = currentIndex, idx + 1 < queue.count {
            next()
        } else {
            isPlaying = false
            progress = duration
            updateNowPlaying()
        }
    }

    private func fetchLyrics() {
        lyricsTask?.cancel()
        guard let track = current else { lyricsState = .idle; return }
        lyricsState = .loading
        lyricsTask = Task {
            let result = await LyricsClient.fetchLyrics(for: track)
            guard !Task.isCancelled, self.current?.id == track.id else { return }
            if let result, result.instrumental || !result.lines.isEmpty || !(result.plainText ?? "").isEmpty {
                lyricsState = .loaded(result)
            } else {
                lyricsState = .unavailable
            }
        }
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* Playback still works in the foreground; background audio needs the category. */ }
    }

    // MARK: Lock screen / Control Center

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.isPlaying == false { self?.togglePlay() }
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.isPlaying == true { self?.togglePlay() }
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress,
            MPMediaItemPropertyPlaybackDuration: max(duration, track.duration),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artworkURL = track.artworkURL {
            if let cached = artworkCache[track.id] {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: cached.size) { _ in cached }
            } else {
                Task {
                    if let (data, _) = try? await URLSession.shared.data(from: artworkURL),
                       let image = UIImage(data: data) {
                        self.artworkCache[track.id] = image
                        self.updateNowPlaying()
                    }
                }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - Views

struct MusicView: View {
    @EnvironmentObject var store: DownloadStore
    @EnvironmentObject var player: MusicPlayer
    @Environment(\.openURL) var openURL
    @State private var query = ""
    @State private var results: [MusicTrack] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var localTracks: [MusicTrack] = []
    @State private var showingNowPlaying = false

    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aif", "aiff"]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Cari lagu, artis, album…", text: $query)
                            .autocapitalization(.none).autocorrectionDisabled()
                            .onSubmit { search() }
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        }
                    }
                    Button("Cari") { search() }.disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                    Text("Hasilnya preview 30 detik dari iTunes (gratis, tanpa akun). File yang sudah kamu download bisa diputar penuh di bawah. Lirik diambil dari lrclib saat lagu diputar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isSearching {
                    Section { ProgressView("Mencari…") }
                } else if let error = searchError {
                    Section { Text(error).foregroundStyle(.red).font(.caption) }
                } else if !results.isEmpty {
                    Section("Hasil pencarian (preview)") {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, track in
                            MusicTrackRow(track: track, isCurrent: player.current?.id == track.id, isPlaying: player.isPlaying, isLiked: player.isLiked(track)) {
                                player.play(tracks: results, index: index)
                            } onLike: {
                                player.toggleLike(track)
                            } onYouTubeMusic: {
                                if let url = track.youTubeMusicSearchURL { openURL(url) }
                            }
                        }
                    }
                }
                if !player.liked.isEmpty {
                    Section("Disukai") {
                        ForEach(Array(player.liked.enumerated()), id: \.element.id) { index, track in
                            MusicTrackRow(track: track, isCurrent: player.current?.id == track.id, isPlaying: player.isPlaying, isLiked: true) {
                                player.play(tracks: player.liked, index: index)
                            } onLike: {
                                player.toggleLike(track)
                            } onYouTubeMusic: {
                                if let url = track.youTubeMusicSearchURL { openURL(url) }
                            }
                        }
                    }
                }
                Section("Di perangkat ini (file download, putar penuh)") {
                    if localTracks.isEmpty {
                        Text("Belum ada file audio di folder download. Download MP3/M4A dari browser, lalu file-nya muncul di sini dan bisa diputar penuh dengan lirik.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(localTracks.enumerated()), id: \.element.id) { index, track in
                        MusicTrackRow(track: track, isCurrent: player.current?.id == track.id, isPlaying: player.isPlaying, isLiked: player.isLiked(track)) {
                            player.play(tracks: localTracks, index: index)
                        } onLike: {
                            player.toggleLike(track)
                        } onYouTubeMusic: {
                            if let url = track.youTubeMusicSearchURL { openURL(url) }
                        }
                    }
                }
            }
            .navigationTitle("Music")
            .task { await loadLocalTracks() }
            .onReceive(store.$items.dropFirst()) { _ in Task { await loadLocalTracks() } }
            .safeAreaInset(edge: .bottom) {
                if player.current != nil { miniPlayer }
            }
            .sheet(isPresented: $showingNowPlaying) {
                if let track = player.current {
                    NowPlayingView(track: track)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isSearching = true
        searchError = nil
        Task {
            do {
                let found = try await ITunesSearch.search(q)
                results = found
                if found.isEmpty { searchError = "Tidak ada hasil untuk \"\(q)\"." }
            } catch {
                searchError = "Pencarian gagal: \(error.localizedDescription)"
            }
            isSearching = false
        }
    }

    private func loadLocalTracks() async {
        let files = store.downloadedFiles().filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
        var tracks: [MusicTrack] = []
        for url in files {
            let rawName = url.deletingPathExtension().lastPathComponent
            let pretty = rawName.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            var duration: TimeInterval = 0
            let asset = AVURLAsset(url: url)
            if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
                duration = seconds
            }
            tracks.append(MusicTrack(
                id: "local:\(url.path)",
                title: pretty,
                artist: "File lokal",
                album: "",
                artworkURL: nil,
                streamURL: url,
                duration: duration,
                isLocal: true
            ))
        }
        localTracks = tracks.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    // MARK: Mini player (Spotify-style, docked above the tab bar)

    private var miniPlayer: some View {
        Button { showingNowPlaying = true } label: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    MusicArtwork(url: player.current?.artworkURL, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.current?.title ?? "").lineLimit(1).font(.subheadline.weight(.semibold))
                        Text(player.current?.artist ?? "").lineLimit(1).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        player.togglePlay()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.body)
                            .frame(width: 36, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(player.currentIndex.map { $0 + 1 >= player.queue.count } ?? true)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                ProgressView(value: player.progress, total: max(player.duration, 1))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }
            .background(.ultraThinMaterial)
        }
        .buttonStyle(.plain)
    }
}

struct MusicArtwork: View {
    var url: URL?
    var size: CGFloat
    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(.secondarySystemBackground))
                    }
                }
            } else {
                Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
    }
}

struct MusicTrackRow: View {
    var track: MusicTrack
    var isCurrent: Bool
    var isPlaying: Bool
    var isLiked: Bool
    var onPlay: () -> Void
    var onLike: () -> Void
    var onYouTubeMusic: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            MusicArtwork(url: track.artworkURL, size: 48)
            Button(action: onPlay) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).lineLimit(1).font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? .accent : .primary)
                    Text("\(track.artist)\(track.album.isEmpty ? "" : " · \(track.album)")")
                        .lineLimit(1).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if isCurrent && isPlaying {
                Image(systemName: "waveform").foregroundStyle(.accent).font(.caption)
            }
            Text(track.durationLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button(action: onLike) {
                Image(systemName: isLiked ? "heart.fill" : "heart").foregroundStyle(isLiked ? .red : .secondary)
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button { onPlay() } label: { Label("Putar", systemImage: "play.fill") }
            Button { onLike() } label: { Label(isLiked ? "Hapus dari Disukai" : "Suka", systemImage: "heart") }
            Button { onYouTubeMusic() } label: { Label("Buka di YouTube Music", systemImage: "play.rectangle.on.rectangle") }
        }
    }
}

// MARK: - Now Playing + synced lyrics

struct NowPlayingView: View {
    @EnvironmentObject var player: MusicPlayer
    @Environment(\.openURL) var openURL
    var track: MusicTrack
    @State private var scrubValue: TimeInterval?
    @Environment(\.dismiss) var dismiss

    private var sliderValue: Binding<TimeInterval> {
        Binding(
            get: { scrubValue ?? player.progress },
            set: { scrubValue = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        MusicArtwork(url: track.artworkURL, size: 240)
                            .shadow(radius: 12)
                            .padding(.top, 8)
                        VStack(spacing: 4) {
                            Text(track.title).font(.title3.weight(.bold)).multilineTextAlignment(.center)
                            Text(track.artist).font(.subheadline).foregroundStyle(.secondary)
                            if !track.album.isEmpty {
                                Text(track.album).font(.caption).foregroundStyle(.secondary)
                            }
                            if !track.isLocal {
                                Text("Preview 30 detik · iTunes").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        VStack(spacing: 6) {
                            Slider(value: sliderValue, in: 0...max(player.duration, 1)) { editing in
                                if !editing, let value = scrubValue {
                                    player.seek(to: value)
                                    scrubValue = nil
                                }
                            }
                            HStack {
                                Text(formatTime(scrubValue ?? player.progress)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Spacer()
                                Text(formatTime(player.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 4)
                        HStack(spacing: 36) {
                            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title2) }
                            Button { player.togglePlay() } label: {
                                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 64))
                            }
                            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title2) }
                                .disabled(player.currentIndex.map { $0 + 1 >= player.queue.count } ?? true)
                        }
                        HStack(spacing: 20) {
                            Button { player.toggleLike(track) } label: {
                                Label(player.isLiked(track) ? "Disukai" : "Suka", systemImage: player.isLiked(track) ? "heart.fill" : "heart")
                            }
                            .buttonStyle(.bordered)
                            .tint(player.isLiked(track) ? .red : nil)
                            if let url = track.youTubeMusicSearchURL {
                                Button { openURL(url) } label: {
                                    Label("YouTube Music", systemImage: "play.rectangle.on.rectangle")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        lyricsSection(proxy: proxy)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Selesai") { dismiss() } } }
        }
    }

    @ViewBuilder
    private func lyricsSection(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "text.quote")
                Text("Lirik").font(.headline)
                Spacer()
                Text("lrclib").font(.caption).foregroundStyle(.secondary)
            }
            switch player.lyricsState {
            case .idle, .loading:
                ProgressView("Mencari lirik…").frame(maxWidth: .infinity)
            case .unavailable:
                Text("Lirik tidak ditemukan untuk lagu ini. Coba putar versi lain dari hasil pencarian, atau buka di YouTube Music.")
                    .font(.subheadline).foregroundStyle(.secondary)
            case .loaded(let result):
                if result.instrumental {
                    Text("Lagu instrumental — tidak ada lirik.").font(.subheadline).foregroundStyle(.secondary)
                } else if !result.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(result.lines.enumerated()), id: \.element.id) { index, line in
                            let isCurrent = player.currentLyricIndex == index
                            Button { player.seekToLyric(line) } label: {
                                Text(line.text)
                                    .font(isCurrent ? .body.weight(.bold) : .body)
                                    .foregroundStyle(isCurrent ? .primary : .secondary)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .onChange(of: player.currentLyricIndex) { idx in
                        if let idx { withAnimation { proxy.scrollTo(idx, anchor: .center) } }
                    }
                } else if let plain = result.plainText, !plain.isEmpty {
                    Text(plain).font(.body).textSelection(.enabled)
                } else {
                    Text("Lirik tidak ditemukan untuk lagu ini.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
