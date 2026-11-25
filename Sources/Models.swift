import Foundation

// Mister Download Manager — iOS port (SwiftUI reimplementation).
// Original desktop app: https://github.com/anefzaoui/misterdownloadmanager (GPL-3.0, Rust/egui).
// This iOS version is a clean-room SwiftUI reimplementation of the features that
// iOS sandboxing allows. Desktop-only features (browser native-messaging host,
// system tray, wake/shutdown, yt-dlp/ffmpeg binaries, 7-Zip) are not ported;
// see README.md for the honest scope list.

enum DownloadCategory: String, CaseIterable, Codable, Identifiable {
    case all = "All"
    case video = "Video"
    case music = "Music"
    case documents = "Documents"
    case compressed = "Compressed"
    case programs = "Programs"
    case images = "Images"
    case torrents = "Torrents"
    case other = "Other"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .video: return "film"
        case .music: return "music.note"
        case .documents: return "doc.text"
        case .compressed: return "archivebox"
        case .programs: return "app.badge"
        case .images: return "photo"
        case .torrents: return "magnet"
        case .other: return "doc"
        }
    }

    static func from(fileName: String, mime: String?) -> DownloadCategory {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ["torrent"].contains(ext) { return .torrents }
        if ["mp4","mkv","mov","avi","webm","m4v","ts","m3u8"].contains(ext) { return .video }
        if ["mp3","flac","wav","aac","ogg","m4a"].contains(ext) { return .music }
        if ["pdf","doc","docx","txt","epub","xls","xlsx","ppt","pptx","md","csv"].contains(ext) { return .documents }
        if ["zip","rar","7z","tar","gz","xz","iso","dmg"].contains(ext) { return .compressed }
        if ["ipa","apk","exe","dmg","pkg","msi"].contains(ext) { return .programs }
        if ["jpg","jpeg","png","gif","webp","heic","svg","bmp"].contains(ext) { return .images }
        if let mime {
            if mime.hasPrefix("video/") { return .video }
            if mime.hasPrefix("audio/") { return .music }
            if mime.hasPrefix("image/") { return .images }
            if mime.contains("pdf") || mime.contains("document") { return .documents }
        }
        return .other
    }
}

enum DownloadState: String, Codable {
    case queued, downloading, paused, completed, failed, verifying
    var label: String {
        switch self {
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .verifying: return "Verifying"
        }
    }
}

struct SegmentState: Codable, Equatable {
    var start: Int64
    var end: Int64 // inclusive; -1 = unknown / to end of file
    var downloaded: Int64
    var isDone: Bool
    var fileName: String
}

struct DownloadItem: Identifiable, Codable {
    var id: UUID = UUID()
    var url: String
    var fileName: String
    var category: DownloadCategory
    var state: DownloadState = .queued
    var totalBytes: Int64?
    var downloadedBytes: Int64 = 0
    var speedBytesPerSec: Double = 0
    var connections: Int = 8
    var segments: [SegmentState] = []
    var createdAt: Date = Date()
    var completedAt: Date?
    var referer: String?
    var userAgent: String?
    var checksumType: String? // MD5 / SHA1 / SHA256
    var checksumValue: String?
    var checksumVerified: Bool?
    var errorMessage: String?
    var isTorrent: Bool = false
    var torrentName: String?
    var resumeSupported: Bool = true
    var mimeType: String?
    var site: String?

    var progress: Double {
        guard let total = totalBytes, total > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(total))
    }
    var remainingBytes: Int64? {
        guard let total = totalBytes else { return nil }
        return max(0, total - downloadedBytes)
    }
    var etaSeconds: Double? {
        guard speedBytesPerSec > 1, let rem = remainingBytes else { return nil }
        return Double(rem) / speedBytesPerSec
    }
    var host: String { URL(string: url)?.host ?? "" }
}

struct AppSettings: Codable {
    var maxConnections: Int = 8
    var speedLimitKBps: Int = 0 // 0 = unlimited
    var wifiOnly: Bool = false
    var autoResumeOnLaunch: Bool = true
    var startPaused: Bool = false
    var maxConcurrentDownloads: Int = 3
    var schedulerEnabled: Bool = false
    var schedulerStartHour: Int = 22
    var schedulerStartMinute: Int = 0
    var schedulerStopHour: Int = 6
    var schedulerStopMinute: Int = 0
    var schedulerShutdownAfter: Bool = false // desktop-only; kept as a stored preference, no-op on iOS
    var queueEnabled: Bool = false
    var userAgent: String = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
    var language: String = "en"
    var themeName: String = "premiumDark"
    var interfaceScale: Double = 1.0
    var notificationsEnabled: Bool = true
    var clipboardMonitor: Bool = true
    var proxyEnabled: Bool = false
    var proxyHost: String = ""
    var proxyPort: Int = 8080
    var proxyType: String = "HTTP" // HTTP / SOCKS
    var customDNS: String = "" // stored; iOS URLSession cannot override DNS per-app, shown honestly in UI
    var remoteControlEnabled: Bool = false
    var remotePort: Int = 8080
    // Legacy plaintext holders: values from older installs are migrated to
    // the Keychain on load (see MDMSecrets) and these stay empty at rest.
    var realDebridKey: String = ""
    var allDebridKey: String = ""
    var premiumizeKey: String = ""
    var torboxKey: String = ""
    var megaDebridKey: String = ""
    var defaultCategory: String = "All"

    static let `default` = AppSettings()
}

enum ThemeName: String, CaseIterable, Identifiable {
    case system, classic, dark, light, highContrast, metro, adwaita, breeze, luna, aero, aqua
    case premiumDark, premiumLight

    /// Themes offered in Settings (Paket B). Legacy desktop themes stay in
    /// the enum so saved values keep decoding, but are no longer offered.
    static var pickerCases: [ThemeName] { [.system, .premiumDark, .premiumLight] }
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .classic: return "Classic"
        case .dark: return "Dark"
        case .light: return "Light"
        case .highContrast: return "High contrast"
        case .premiumDark: return "Premium Dark"
        case .premiumLight: return "Premium Light"
        case .metro: return "Metro"
        case .adwaita: return "Adwaita"
        case .breeze: return "Breeze"
        case .luna: return "Luna"
        case .aero: return "Aero"
        case .aqua: return "Aqua"
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let b = Double(bytes)
    if b < 1024 { return "\(bytes) B" }
    if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
    if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / (1024 * 1024)) }
    return String(format: "%.2f GB", b / (1024 * 1024 * 1024))
}
func formatBytes(_ bytes: Double) -> String { formatBytes(Int64(bytes)) }
func formatSpeed(_ bps: Double) -> String {
    if bps <= 0 { return "—" }
    return formatBytes(bps) + "/s"
}
func formatETA(_ seconds: Double?) -> String {
    guard let s = seconds, s.isFinite, s > 0 else { return "—" }
    let total = Int(s)
    if total < 60 { return "\(total)s" }
    if total < 3600 { return "\(total / 60)m \(total % 60)s" }
    return "\(total / 3600)h \((total % 3600) / 60)m"
}
