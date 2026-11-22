import Foundation

/// Page video / gallery extraction, MDM-style (video button + gallery-dl idea),
/// reimplemented for iOS without yt-dlp/ffmpeg: direct <video>/mp4/m3u8 links
/// found in the page HTML, plus <img> gallery links. Sites that hide their
/// streams behind JS/DRM will not yield a direct link here — that is stated
/// in the UI instead of faked.
struct GrabbedMedia: Identifiable, Hashable {
    var id = UUID()
    var url: String
    var kind: Kind
    var label: String
    enum Kind { case video, playlist, image, audio }
}

enum VideoGrabber {
    static func fetchPage(url: URL, settings: AppSettings) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(settings.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { throw NSError(domain: "MDMGrabber", code: 0, userInfo: [NSLocalizedDescriptionKey: "Halaman tidak bisa dibuka."]) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func extract(from html: String, baseURL: URL) -> [GrabbedMedia] {
        var found: [GrabbedMedia] = []
        var seen = Set<String>()
        func add(_ raw: String, kind: GrabbedMedia.Kind, label: String) {
            let cleaned = raw.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            guard let resolved = URL(string: cleaned, relativeTo: baseURL)?.absoluteURL.absoluteString,
                  !seen.contains(resolved), resolved.hasPrefix("http") else { return }
            seen.insert(resolved)
            found.append(GrabbedMedia(url: resolved, kind: kind, label: label))
        }
        let patterns: [(String, GrabbedMedia.Kind, String)] = [
            (#"https?://[^\s"'<>]+\.m3u8(?:\?[^\s"'<>]*)?"#, .playlist, "HLS playlist (.m3u8)"),
            (#"https?://[^\s"'<>]+\.mp4(?:\?[^\s"'<>]*)?"#, .video, "MP4"),
            (#"https?://[^\s"'<>]+\.(?:webm|mov|m4v)(?:\?[^\s"'<>]*)?"#, .video, "Video"),
            (#"https?://[^\s"'<>]+\.(?:mp3|m4a|flac|ogg)(?:\?[^\s"'<>]*)?"#, .audio, "Audio"),
            (#"<video[^>]+src="([^"]+)""#, .video, "Video tag"),
            (#"<source[^>]+src="([^"]+)""#, .video, "Video source"),
        ]
        for (pattern, kind, label) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            for match in regex.matches(in: html, range: range) {
                let capture = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                if let swiftRange = Range(capture, in: html) { add(String(html[swiftRange]), kind: kind, label: label) }
            }
        }
        // Gallery images (limit to a sane number).
        if let regex = try? NSRegularExpression(pattern: #"<img[^>]+src="([^"]+)""#, options: .caseInsensitive) {
            let range = NSRange(html.startIndex..., in: html)
            var count = 0
            for match in regex.matches(in: html, range: range) where count < 50 {
                if let swiftRange = Range(match.range(at: 1), in: html) {
                    add(String(html[swiftRange]), kind: .image, label: "Image")
                    count += 1
                }
            }
        }
        return found
    }

    /// Downloads an HLS (.m3u8) stream: picks the highest-bandwidth variant,
    /// fetches segments in order and concatenates them into one .ts file.
    /// Encrypted (AES-128) playlists are not supported on iOS here.
    static func downloadHLS(playlistURL: URL, destination: URL, settings: AppSettings, onProgress: ((Int64, Int64?) -> Void)?) async throws {
        func fetchText(_ url: URL) async throws -> String {
            var req = URLRequest(url: url)
            req.setValue(settings.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            return String(data: data, encoding: .utf8) ?? ""
        }
        var text = try await fetchText(playlistURL)
        if text.contains("#EXT-X-STREAM-INF") {
            // Master playlist: pick the variant with the highest BANDWIDTH.
            var bestURL: URL?; var bestBW = -1
            let lines = text.components(separatedBy: .newlines)
            for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
                var bw = 0
                if let r = line.range(of: "BANDWIDTH=") {
                    let rest = line[r.upperBound...]
                    bw = Int(rest.prefix(while: { $0.isNumber })) ?? 0
                }
                if i + 1 < lines.count, bw >= bestBW {
                    bestBW = bw
                    bestURL = URL(string: lines[i + 1].trimmingCharacters(in: .whitespaces), relativeTo: playlistURL)?.absoluteURL
                }
            }
            guard let variant = bestURL else { throw NSError(domain: "MDMHLS", code: 0, userInfo: [NSLocalizedDescriptionKey: "Playlist master tidak punya varian."]) }
            text = try await fetchText(variant)
            // Rebase segment URLs against the variant URL below.
            return try await downloadSegments(text: text, base: variant, destination: destination, settings: settings, onProgress: onProgress)
        }
        try await downloadSegments(text: text, base: playlistURL, destination: destination, settings: settings, onProgress: onProgress)
    }

    private static func downloadSegments(text: String, base: URL, destination: URL, settings: AppSettings, onProgress: ((Int64, Int64?) -> Void)?) async throws {
        if text.contains("#EXT-X-KEY") {
            throw NSError(domain: "MDMHLS", code: 0, userInfo: [NSLocalizedDescriptionKey: "Playlist terenkripsi (AES-128) tidak didukung di port iOS ini."])
        }
        let segmentLines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !segmentLines.isEmpty else { throw NSError(domain: "MDMHLS", code: 0, userInfo: [NSLocalizedDescriptionKey: "Tidak ada segmen di playlist."]) }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        var done: Int64 = 0
        for line in segmentLines {
            try Task.checkCancellation()
            guard let segURL = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            let tmp = destination.appendingPathExtension("seg")
            _ = try await DownloadEngine.downloadRange(url: segURL, range: nil, destination: tmp, settings: settings, referer: nil, limiter: nil, onBytes: nil)
            if let data = try? Data(contentsOf: tmp) {
                if let handle = try? FileHandle(forWritingTo: destination) {
                    try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
                }
                done += Int64(data.count)
            }
            try? FileManager.default.removeItem(at: tmp)
            onProgress?(done, nil)
        }
    }
}
