import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Browser, ad-block, tab groups & "Ask AI"
//
// What iOS allows here, and what it does not:
// - YES: an in-app WKWebView browser with tabs, tab groups, private
//   (incognito) tabs, download capture into the MDM queue, video/media
//   finding, and content-rule ad blocking.
// - YES: built-in + custom URL filters running TOGETHER (both lists are
//   compiled into one WKContentRuleList; allowlist rules win).
// - YES: "Ask AI" about the open page via the providers' own APIs
//   (Gemini, ChatGPT, Claude). API keys are entered in the app and kept
//   in the device Keychain — never in the app's settings file.
// - NO: real Chrome extensions. Chrome's extension APIs do not exist on
//   iOS. The "extensions" here are small JavaScript userscripts the user
//   can toggle, edit and add — same mechanism Safari extensions use,
//   without pretending to be Chrome extensions.
// - NO: a built-in Muse API. Meta does not publish a public API for the
//   Meta AI assistant, so the Muse option opens meta.ai in a new tab
//   and copies the question + page context for pasting. It is labelled
//   as a web hand-off, not an in-app answer.
// - The glass look uses system materials (ultraThinMaterial), which render
//   as Safari-style liquid glass on iOS 26 and as frosted glass on
//   iOS 16/17. No iOS 26-only API is used, so the iOS 16 target still
//   builds: no glassEffect, no ContentUnavailableView, no parameter-less
//   onChange, no List(selection:) with a non-optional binding.

struct BrowserExtension: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var source: String
    var enabled: Bool
    var atDocumentStart: Bool = false
    /// @match/@include patterns from the userscript header. Empty means
    /// the script runs on every page (the old behaviour, kept for the
    /// builtins and hand-written extensions).
    var matches: [String] = []
    /// @exclude patterns: pages matching one never run the script.
    var excludes: [String] = []

    /// Tampermonkey-style @match glob: scheme/host/path with `*`
    /// wildcards; `*.host` matches the host and its subdomains.
    static func patternMatches(_ pattern: String, url: URL) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        if p == "<all_urls>" { return true }
        guard let schemeEnd = p.range(of: "://") else { return false }
        let scheme = String(p[..<schemeEnd.lowerBound]).lowercased()
        let rest = String(p[schemeEnd.upperBound...])
        guard let slash = rest.firstIndex(of: "/") else { return false }
        let hostPart = String(rest[..<slash]).lowercased()
        let pathPart = String(rest[slash...])
        if scheme != "*" && scheme != (url.scheme ?? "").lowercased() { return false }
        let host = (url.host ?? "").lowercased()
        if hostPart != "*" {
            if hostPart.hasPrefix("*.") {
                let base = String(hostPart.dropFirst(2))
                if host != base && !host.hasSuffix("." + base) { return false }
            } else if host != hostPart { return false }
        }
        let escaped = NSRegularExpression.escapedPattern(for: pathPart).replacingOccurrences(of: "\\*", with: ".*")
        guard let regex = try? NSRegularExpression(pattern: "^" + escaped + "$") else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        let full = path + (url.query.map { "?" + $0 } ?? "")
        return regex.firstMatch(in: full, range: NSRange(full.startIndex..., in: full)) != nil
    }

    /// Whether this script runs on a page. With no URL yet (fresh tab)
    /// only match-less scripts run; the page gets re-checked on every
    /// navigation commit.
    func runs(on url: URL?) -> Bool {
        guard let url else { return matches.isEmpty && excludes.isEmpty }
        if excludes.contains(where: { Self.patternMatches($0, url: url) }) { return false }
        if matches.isEmpty { return true }
        return matches.contains(where: { Self.patternMatches($0, url: url) })
    }

    /// Decodes script bytes, tolerating UTF-16/Latin-1 files and a BOM,
    /// which some editors (notably on Windows) produce.
    static func decodeScript(_ data: Data) -> String? {
        for encoding in [String.Encoding.utf8, .utf16, .isoLatin1] {
            if var text = String(data: data, encoding: encoding) {
                if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
                return text
            }
        }
        return nil
    }

    /// Userscript metadata block (// ==UserScript== … // ==/UserScript==):
    /// @name becomes the extension name, @run-at document-start picks
    /// "Awal dokumen" timing, @match/@include limit the pages, @exclude
    /// removes pages.
    static func userscriptMeta(_ source: String) -> (name: String?, atStart: Bool, matches: [String], excludes: [String]) {
        var name: String?
        var atStart = false
        var matches: [String] = []
        var excludes: [String] = []
        for line in source.components(separatedBy: .newlines).prefix(50) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "// ==/UserScript==" { break }
            guard t.hasPrefix("//") else { continue }
            let body = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
            // Split "@key value" on the first whitespace, so "@namespace"
            // is never mistaken for "@name" (the old prefix check did).
            let parts = body.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "@name": name = String(parts[1])
            case "@run-at": atStart = parts[1].lowercased().contains("document-start")
            case "@match", "@include": matches.append(String(parts[1]))
            case "@exclude": excludes.append(String(parts[1]))
            default: break
            }
        }
        return (name, atStart, matches, excludes)
    }

    static let builtins: [BrowserExtension] = [
        BrowserExtension(
            name: "Hide cookie banners",
            source: "(() => { document.querySelectorAll('[class*=\"cookie\"], [id*=\"cookie\"], [class*=\"consent\"], [id*=\"consent\"], [class*=\"gdpr\"], [id*=\"gdpr\"]').forEach(el => { el.style.display = 'none'; }); })();",
            enabled: true
        ),
        BrowserExtension(
            name: "Remove full-screen overlays",
            source: "(() => { document.querySelectorAll('*').forEach(el => { const s = getComputedStyle(el); const r = el.getBoundingClientRect(); if (s.position === 'fixed' && r.height > window.innerHeight * 0.5) { el.style.display = 'none'; } }); })();",
            enabled: false
        ),
    ]
}

struct BrowserBookmark: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var urlString: String

    static let defaults: [BrowserBookmark] = [
        BrowserBookmark(title: "Google", urlString: "https://www.google.com"),
        BrowserBookmark(title: "YouTube", urlString: "https://www.youtube.com"),
        BrowserBookmark(title: "GitHub", urlString: "https://github.com"),
        BrowserBookmark(title: "Wikipedia", urlString: "https://www.wikipedia.org"),
    ]
}

struct BrowserSettings: Codable {
    var adBlockEnabled: Bool = true
    var customAdBlockEnabled: Bool = true
    // One filter per line. Forms: "ads.example.com", "||tracker.example", "*.adnxs.com",
    // "*banner*", or a raw regex between /.../. Lines starting with "@@" are allowlist entries.
    var customBlockFilters: [String] = ["||doubleclick.net", "||googlesyndication.com", "*popunder*", "*pop-up*"]
    var customAllowFilters: [String] = []
    var extensions: [BrowserExtension] = BrowserExtension.builtins
    var homePage: String = "https://www.google.com"
    var desktopMode: Bool = false
    // Kept only so saved settings from the old "Desktop site" switch still
    // decode; loadBrowserSettings migrates it once to the preset below.
    // The preset is the only source of the user agent now.
    // Ready-made user-agent template id ("default" = WebKit's own UA).
    var userAgentPreset: String = UserAgentPreset.default.rawValue

    /// The override UA for the selected template, or nil for WebKit's own.
    var effectiveUserAgent: String? {
        UserAgentPreset(rawValue: userAgentPreset)?.uaString
    }

    /// www-insensitive, subdomain-aware match against a per-site list,
    /// the same rule the zoom and host-list toggles use.
    private func siteEntryMatches(_ host: String, _ entry: String) -> Bool {
        func bare(_ s: String) -> String {
            var h = BrowserSession.cleanHostEntry(s)
            if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
            return h
        }
        let h = bare(host), b = bare(entry)
        return !b.isEmpty && (h == b || h.hasSuffix("." + b))
    }

    func isSiteConfigEnabled(for host: String) -> Bool {
        siteConfigEnabled.contains { siteEntryMatches(host, $0) }
    }

    func siteUAOverride(for host: String) -> UserAgentPreset? {
        guard isSiteConfigEnabled(for: host) else { return nil }
        for (key, rawValue) in siteUserAgent where siteEntryMatches(host, key) {
            if let preset = UserAgentPreset(rawValue: rawValue) { return preset }
        }
        return nil
    }

    func isSiteDesktopMode(for host: String) -> Bool {
        isSiteConfigEnabled(for: host) && siteDesktopMode.contains { siteEntryMatches(host, $0) }
    }

    func areSiteImagesBlocked(for host: String) -> Bool {
        isSiteConfigEnabled(for: host) && siteImagesBlocked.contains { siteEntryMatches(host, $0) }
    }

    func isSiteJavaScriptBlocked(for host: String) -> Bool {
        isSiteConfigEnabled(for: host) && siteJavaScriptBlocked.contains { siteEntryMatches(host, $0) }
    }
    var searchEngine: String = "Google"
    // Media: background playback (incl. YouTube) + Picture in Picture.
    // Both default ON and can be switched off in settings.
    var backgroundPlayback: Bool = true
    var pictureInPicture: Bool = true
    // Content settings.
    var blockPopups: Bool = true
    var linkPreview: Bool = true
    var detectAddresses: Bool = true
    var webInspector: Bool = true
    // DevTools entry point: when on, the floating DevTools button and
    // the ⋯-menu entry appear in the browser; off hides both.
    var showDevToolsButton: Bool = true
    // Timer bypass: speed up countdown waits on download pages.
    var skipTimers: Bool = false
    // Freeze timers: on these hosts, page timers (setTimeout/setInterval)
    // never fire — countdown/trial timers stop instead of speeding up.
    // Hosts, e.g. ["example.com"]; subdomains match too.
    var freezeTimerHosts: [String] = []
    // Compatibility mode hosts (e.g. DRM video sites like cubmu.com):
    // on these pages AdBlock rules, userscripts and the desktop user
    // agent are switched off, because they can break license/key
    // requests and player code. The page itself still runs in WKWebView.
    var drmCompatHosts: [String] = []
    // Per-site zoom (Safari-style): clean host -> scale, 1.0 = 100%.
    // Steps of 0.1 within 0.5...2.0; hosts without an entry use 100%.
    // Persisted with the rest of the settings, so old saved JSON (without
    // this key) still decodes via the default.
    var siteZoom: [String: Double] = [:]
    // No-redirect mode: download clicks go straight to the final link,
    // cross-host popups are dropped.
    var noRedirects: Bool = true
    // Reynard/Firefox-style privacy, adapted to WebKit (no jailbreak):
    // Enhanced Tracking Protection level: "off" | "standard" | "strict".
    var trackingProtection: String = "standard"
    // Firefox HTTPS-Only mode: upgrade http:// main-frame navigations
    // to https:// (local/LAN hosts are left alone).
    var httpsOnly: Bool = false
    // Hosts exempt from tracking protection / blocking.
    var siteExceptions: [String] = []

    // Per-site configuration (Via-style Site configuration screen, opened
    // from the shield popup): the master switch + per-host overrides.
    // A missing entry means "follow the global default".
    var siteConfigEnabled: [String] = []
    var siteUserAgent: [String: String] = [:]
    var siteDesktopMode: [String] = []
    var siteImagesBlocked: [String] = []
    var siteJavaScriptBlocked: [String] = []
    // Browser gestures (Reynard lets each gesture be toggled individually).
    var gestureEdgeSwipe: Bool = true
    var gesturePullRefresh: Bool = true
    var gestureHardReload: Bool = true
    var bookmarks: [BrowserBookmark] = BrowserBookmark.defaults
    // Ask AI: provider id ("Gemini", "ChatGPT", "Claude", "Muse") + model per provider.
    // API keys are NOT stored here — see KeychainHelper in BrowserAI.swift.
    var aiProvider: String = "Gemini"
    var aiModels: [String: String] = [
        "Gemini": "gemini-2.0-flash",
        "ChatGPT": "gpt-4o-mini",
        "Claude": "claude-3-5-haiku-20241022",
    ]
}

// MARK: - User-agent templates ("tinggal pilih")

/// Ready-made user-agent strings. `.default` means no override: WKWebView
/// sends its own UA (mobile Safari on this device).
enum UserAgentPreset: String, CaseIterable, Identifiable {
    case `default`, iphone, ipad, mac, chromeWindows, chromeAndroid, firefoxWindows
    var id: String { rawValue }
    var label: String {
        switch self {
        case .default: return "Default (perangkat ini)"
        case .iphone: return "Safari iPhone"
        case .ipad: return "Safari iPad"
        case .mac: return "Safari Mac (desktop)"
        case .chromeWindows: return "Chrome Windows (desktop)"
        case .chromeAndroid: return "Chrome Android"
        case .firefoxWindows: return "Firefox Windows (desktop)"
        }
    }
    var uaString: String? {
        switch self {
        case .default: return nil
        case .iphone: return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
        case .ipad: return "Mozilla/5.0 (iPad; CPU OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
        case .mac: return "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        case .chromeWindows: return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        case .chromeAndroid: return "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
        case .firefoxWindows: return "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0"
        }
    }
}

// MARK: - Search engines (Google is the default)

enum SearchEngine {
    static let all = ["Google", "DuckDuckGo", "Bing", "Yahoo", "Ecosia", "Brave"]

    static func searchURL(for engine: String, query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch engine {
        case "DuckDuckGo": return URL(string: "https://duckduckgo.com/?q=\(q)")
        case "Bing": return URL(string: "https://www.bing.com/search?q=\(q)")
        case "Yahoo": return URL(string: "https://search.yahoo.com/search?p=\(q)")
        case "Ecosia": return URL(string: "https://www.ecosia.org/search?q=\(q)")
        case "Brave": return URL(string: "https://search.brave.com/search?q=\(q)")
        default: return URL(string: "https://www.google.com/search?q=\(q)")
        }
    }
}

// MARK: - Small helpers

extension Color {
    init(hex: Int) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

enum RelativeTime {
    static func ago(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Ad-block rule compilation

enum AdBlockRules {
    /// Snapshot date of the bundled Ghostery filter lists (EasyList +
    /// EasyPrivacy, converted to WKContentRuleList JSON by
    /// tools/build-ghostery-rules.py). Part of the compiled-list
    /// identifiers, so a refreshed snapshot recompiles instead of
    /// reusing a stale cached list.
    static let ghosterySnapshot = "2026-11-22"
    static let ghosteryChunkCount = 7
    static let ghosteryNetworkChunkCount = 6

    /// Built-in block patterns (domains/substrings). Only a last-resort
    /// fallback now: the bundled Ghostery lists carry the real blocking.
    static let builtinPatterns: [String] = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "adnxs.com", "criteo.com", "taboola.com", "outbrain.com",
        "adsystem.com", "amazon-adsystem.com", "moatads.com",
        "scorecardresearch.com", "quantserve.com", "adsrvr.org",
        "pubmatic.com", "rubiconproject.com", "openx.net",
        "googletagmanager.com/gtag", "facebook.com/tr",
        "doubleclick.net", "ads.yahoo.com", "advertising.com",
    ]

    /// Well-known tracker/analytics domains, blocked only as
    /// third-party loads when tracking protection is "strict"
    /// (Firefox Strict mode behaviour, adapted to content rules).
    static let strictTrackerDomains: [String] = [
        "google-analytics.com", "googletagmanager.com", "gstatic.com",
        "facebook.net", "facebook.com/tr", "connect.facebook.net",
        "scorecardresearch.com", "quantserve.com", "hotjar.com",
        "mixpanel.com", "segment.io", "segment.com", "amplitude.com",
        "newrelic.com", "nr-data.net", "fullstory.com", "crazyegg.com",
        "matomo.cloud", "piwik.pro", "yandex.ru/metrika",
        "doubleclick.net", "googlesyndication.com", "adservice.google.com",
        "bat.bing.com", "clarity.ms", "tiktok.com", "snapchat.com",
        "linkedin.com/px", "twitter.com/i", "pinterest.com",
        "criteo.com", "taboola.com", "outbrain.com",
    ]

    static func escapeRegex(_ s: String) -> String {
        let specials = "\\.^$|?*+()[]{}"
        return s.map { specials.contains($0) ? "\\\($0)" : String($0) }.joined()
    }

    /// Convert one user filter line into a url-filter regex, or nil to skip it.
    static func regex(for filter: String) -> String? {
        var f = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !f.hasPrefix("!"), !f.hasPrefix("#") else { return nil }
        if f.hasPrefix("@@") { f = String(f.dropFirst(2)) }
        if f.hasPrefix("/") && f.hasSuffix("/") && f.count > 2 {
            return String(f.dropFirst().dropLast())
        }
        if f.hasPrefix("||") {
            let domain = String(f.dropFirst(2)).split(separator: "/").first.map(String.init) ?? ""
            guard !domain.isEmpty else { return nil }
            return ".*://([^/]*\\.)?" + escapeRegex(domain) + "([/?#].*)?$"
        }
        // Wildcards: escape, then turn \* into .*
        let escaped = escapeRegex(f).replacingOccurrences(of: "\\*", with: ".*")
        return ".*" + escaped + ".*"
    }

    /// User rules from settings: custom block filters, then the allowlist
    /// last (ignore-previous-rules only cancels earlier rules, and these
    /// are appended after the Ghostery rules in every chunk).
    static func dynamicRules(settings: BrowserSettings) -> [[String: Any]] {
        var rules: [[String: Any]] = []
        func blockRule(pattern: String) -> [String: Any] {
            ["trigger": ["url-filter": pattern, "resource-type": ["script", "image", "xmlhttprequest", "media", "font", "websocket"]],
             "action": ["type": "block"]]
        }
        func allowRule(pattern: String) -> [String: Any] {
            ["trigger": ["url-filter": pattern],
             "action": ["type": "ignore-previous-rules"]]
        }
        if settings.customAdBlockEnabled {
            for line in settings.customBlockFilters {
                if let r = regex(for: line) { rules.append(blockRule(pattern: r)) }
            }
        }
        // Strict tracking protection: block known trackers, but only
        // when loaded by another site (load-type third-party), so a
        // site's own first-party scripts keep working.
        if settings.trackingProtection == "strict" {
            for domain in strictTrackerDomains {
                let pattern = ".*://([^/]*\\.)?" + escapeRegex(domain) + "([/?#].*)?$"
                rules.append(["trigger": ["url-filter": pattern, "load-type": ["third-party"],
                                          "resource-type": ["script", "image", "xmlhttprequest", "media", "font", "websocket"]],
                              "action": ["type": "block"]])
            }
        }
        // Per-site image blocking (Site configuration): image loads are
        // blocked only while the top page is one of the listed hosts.
        // These come before the allowlist/exception rules so an explicit
        // allowlist entry can still win, like everywhere else.
        for host in settings.siteImagesBlocked where settings.isSiteConfigEnabled(for: host) {
            var h = BrowserSession.cleanHostEntry(host)
            if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
            guard !h.isEmpty else { continue }
            let patterns = ["*://" + h + "/*", "*://*." + h + "/*"]
            rules.append(["trigger": ["url-filter": ".*", "resource-type": ["image"], "if-top-url": patterns],
                          "action": ["type": "block"]])
        }
        for line in settings.customAllowFilters {
            if let r = regex(for: line) { rules.append(allowRule(pattern: r)) }
        }
        // Per-site exceptions (allowlist, last so they win): a bare host
        // matches that host and its subdomains only.
        for host in settings.siteExceptions {
            let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !h.isEmpty else { continue }
            let pattern = ".*://([^/]*\\.)?" + escapeRegex(h) + "([/?#].*)?$"
            rules.append(allowRule(pattern: pattern))
        }
        return rules
    }

    static func bundledChunk(_ index: Int) -> [[String: Any]]? {
        guard let url = Bundle.main.url(forResource: "ghostery-rules-\(index)", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rules
    }

    /// Stable hash (FNV-1a) for compiled-list identifiers: Swift's
    /// hashValue is randomised per launch, so it cannot key the store.
    static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    static func compile(settings: BrowserSettings, completion: @escaping ([WKContentRuleList]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let dynamic = dynamicRules(settings: settings)
            if !settings.adBlockEnabled, dynamic.isEmpty {
                completion([])
                return
            }
            let dynamicJSON = (try? JSONSerialization.data(withJSONObject: dynamic))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let tag = stableHash(dynamicJSON)

            // Candidate rule sets, best first: full Ghostery lists, then
            // network-only, then the tiny built-in patterns. Each set is
            // an array of chunks; the user rules are appended to every
            // chunk so the allowlist cancels Ghostery blocks too.
            var attempts: [[[[String: Any]]]] = []
            if settings.adBlockEnabled {
                var full: [[[String: Any]]] = []
                for i in 1...ghosteryChunkCount {
                    guard let chunk = bundledChunk(i) else { break }
                    full.append(chunk + dynamic)
                }
                if full.count == ghosteryChunkCount { attempts.append(full) }
                var network: [[[String: Any]]] = []
                for i in 1...ghosteryNetworkChunkCount {
                    guard let chunk = bundledChunk(i) else { break }
                    network.append(chunk + dynamic)
                }
                if network.count == ghosteryNetworkChunkCount { attempts.append(network) }
            }
            let builtin = builtinPatterns.map { pattern -> [String: Any] in
                ["trigger": ["url-filter": ".*" + escapeRegex(pattern) + ".*",
                             "resource-type": ["script", "image", "xmlhttprequest", "media", "font", "websocket"]],
                 "action": ["type": "block"]]
            }
            attempts.append([(settings.adBlockEnabled ? builtin : []) + dynamic])

            let store = WKContentRuleListStore.default()!
            func loadChunk(_ rules: [[String: Any]], identifier: String, completion: @escaping (WKContentRuleList?) -> Void) {
                store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                    if let list { completion(list); return }
                    guard let data = try? JSONSerialization.data(withJSONObject: rules),
                          let json = String(data: data, encoding: .utf8) else {
                        completion(nil)
                        return
                    }
                    store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, _ in
                        completion(list)
                    }
                }
            }
            func tryAttempt(_ index: Int) {
                guard index < attempts.count else {
                    completion([])
                    return
                }
                let chunks = attempts[index]
                var lists: [WKContentRuleList?] = Array(repeating: nil, count: chunks.count)
                var failed = false
                let lock = NSLock()
                let group = DispatchGroup()
                for (i, chunk) in chunks.enumerated() {
                    group.enter()
                    loadChunk(chunk, identifier: "mdm-ghostery-\(ghosterySnapshot)-\(i)-\(tag)") { list in
                        lock.lock()
                        if let list { lists[i] = list } else { failed = true }
                        lock.unlock()
                        group.leave()
                    }
                }
                group.notify(queue: .global(qos: .userInitiated)) {
                    if !failed {
                        completion(lists.compactMap { $0 })
                    } else {
                        tryAttempt(index + 1)
                    }
                }
            }
            tryAttempt(0)
        }
    }
}

// MARK: - Tabs, groups & session

enum OverviewMode {
    case tabs
    case privateTabs
    case groups
}

struct BrowserTabGroup: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var colorHex: Int = 0x34C759
    var createdAt: Date = Date()
    var tabIDs: [UUID] = []

    var color: Color { Color(hex: colorHex) }

    static let presetColors: [Int] = [
        0x34C759, 0xFF9F0A, 0xFF375F, 0x0A84FF,
        0xBF5AF2, 0xFFD60A, 0x64D2FF, 0xFF453A,
    ]
}

struct BrowserTabState: Identifiable {
    var id: UUID = UUID()
    var title: String = "New Tab"
    var urlString: String = ""
    var progress: Double = 0
    var isLoading: Bool = false
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var pendingURL: URL?
    var isIncognito: Bool = false
    var groupID: UUID? = nil
    var lastUsedAt: Date = Date()

    var showsStartPage: Bool { pendingURL == nil && urlString.isEmpty }
    var host: String { URL(string: urlString)?.host ?? "" }
    var displayTitle: String {
        if !title.isEmpty, title != "New Tab" { return title }
        return host.isEmpty ? "Tab Baru" : host
    }
}

/// A persisted open tab: identity, title, URL, group and recency only.
/// Runtime state (progress, loading, back/forward history) is not
/// saved — a restored tab reloads its URL fresh when the browser
/// opens again. Private (incognito) tabs are never persisted.
struct SavedBrowserTab: Codable {
    var id: UUID
    var title: String
    var urlString: String
    var groupID: UUID?
    var lastUsedAt: Date
}

struct SavedBrowserSession: Codable {
    var tabs: [SavedBrowserTab]
    var groups: [BrowserTabGroup]
    var selectedID: UUID
}

final class BrowserSession: ObservableObject {
    @Published var tabs: [BrowserTabState] = [BrowserTabState()]
    @Published var selectedID: UUID
    @Published var blockedStatus: String = "AdBlock: compiling…"
    @Published var groups: [BrowserTabGroup] = []
    @Published var thumbnails: [UUID: UIImage] = [:]
    @Published var overviewMode: OverviewMode = .tabs
    var webViews: [UUID: WKWebView] = [:]
    // Pending navigations already handed to a WKWebView: updateUIView must
    // not re-issue load() for them, or bare domains (whose committed URL
    // gains a trailing slash) reload forever and the page never finishes.
    var loadingPending: [UUID: URL] = [:]
    // Latest settings, kept in sync by applyRulesAndScripts, for delegate
    // callbacks that do not receive the view's settings value.
    var latestSettings = BrowserSettings()
    // Bottom scroll padding for every web view, so the last row of a page
    // can scroll fully above the floating navbar + tab bar while the page
    // itself still paints to the physical bottom edge (visible through the
    // translucent chrome). Set from the browser view's GeometryReader:
    // real bottom safe-area inset + navbar lift + navbar height.
    var bottomScrollInset: CGFloat = 120 {
        didSet { applyScrollInsets() }
    }

    func applyScrollInsets() {
        for webView in webViews.values {
            // The root ignores the bottom safe area, so the system would
            // reset the bottom inset to zero on every safe-area update and
            // the final rows would hide behind the navbar again. Own the
            // insets instead; the top still follows the real safe area.
            let top = webView.safeAreaInsets.top
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.scrollView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottomScrollInset, right: 0)
            webView.scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: top, left: 0, bottom: bottomScrollInset, right: 0)
            // Fixed/sticky bottom bars ignore the scroll inset, so push
            // the same height to the lift script (bottomBarLiftScript).
            pushBottomBarLift(to: webView)
        }
    }
    // History recording (set by the browser view; skipped for private tabs).
    var onHistoryRecord: ((String, String) -> Void)?
    private var lastHistoryURL: [UUID: String] = [:]
    var onDownloadCaptured: ((URL) -> Void)?
    var onMediaFound: (([URL]) -> Void)?
    // Link long-press menu actions (set by the browser view).
    var onBookmarkAdd: ((String, String) -> Void)?
    var onReadingListAdd: ((String, String) -> Void)?
    // DevTools (F12) state, fed by the in-page bridge script.
    var onDevToolsMessage: ((UUID, [String: Any]) -> Void)?
    // Saved logins (password manager): messages from the in-page login
    // bridge script, and the UI state they drive. Kept on the session
    // (like the DevTools logs) so the script callback never captures
    // the browser view itself.
    var onLoginMessage: ((UUID, [String: Any]) -> Void)?
    @Published var pendingSavePrompt: SaveLoginPrompt?
    @Published var autofillOffer: AutofillOffer?
    var declinedSaveKeys: Set<String> = []
    @Published var consoleLogs: [UUID: [DevConsoleEntry]] = [:]
    @Published var networkLogs: [UUID: [DevNetworkEntry]] = [:]
    @Published var inspectedElement: DevElementInfo?
    @Published var isInspecting: Bool = false

    init() {
        // Restore the previous session: open tabs (URLs only, private
        // tabs excluded) survive the app being closed or swiped out of
        // the app switcher, and reload when the browser opens again.
        if let saved = Self.loadSavedTabs(), !saved.tabs.isEmpty {
            let restored: [BrowserTabState] = saved.tabs.map { s in
                var t = BrowserTabState()
                t.id = s.id
                t.title = s.title
                t.urlString = s.urlString
                t.groupID = s.groupID
                t.lastUsedAt = s.lastUsedAt
                if let url = URL(string: s.urlString), !s.urlString.isEmpty { t.pendingURL = url }
                return t
            }
            tabs = restored
            groups = saved.groups
            selectedID = saved.tabs.contains { $0.id == saved.selectedID } ? saved.selectedID : restored[0].id
        } else {
            let firstTab = BrowserTabState()
            tabs = [firstTab]
            selectedID = firstTab.id
        }
    }

    // MARK: Session persistence (open tabs survive app restarts)

    private static var tabsFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mdm-browser-tabs.json")
    }

    func saveTabs() {
        let saved = SavedBrowserSession(
            tabs: tabs.filter { !$0.isIncognito }.map {
                SavedBrowserTab(id: $0.id, title: $0.title, urlString: $0.urlString,
                                groupID: $0.groupID, lastUsedAt: $0.lastUsedAt)
            },
            groups: groups, selectedID: selectedID)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: Self.tabsFileURL, options: .atomic)
        }
    }

    private static func loadSavedTabs() -> SavedBrowserSession? {
        guard let data = try? Data(contentsOf: tabsFileURL),
              let saved = try? JSONDecoder().decode(SavedBrowserSession.self, from: data) else { return nil }
        return saved
    }

    var selectedTab: BrowserTabState? { tabs.first { $0.id == selectedID } }
    var selectedIndex: Int { max(0, tabs.firstIndex { $0.id == selectedID } ?? 0) }
    var normalTabs: [BrowserTabState] { tabs.filter { !$0.isIncognito } }
    var privateTabs: [BrowserTabState] { tabs.filter { $0.isIncognito } }
    var inactiveTabs: [BrowserTabState] {
        tabs.filter { $0.id != selectedID && Date().timeIntervalSince($0.lastUsedAt) > 21 * 24 * 3600 }
    }

    func select(_ id: UUID) {
        // Never select a tab that no longer exists (e.g. the overview's
        // close-last-tab flow calls onSelect after resetTab already
        // replaced the tab): selecting a dead id left the browser on a
        // blank screen instead of the fresh start page.
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
        touchTab(id)
        saveTabs()
    }

    func touchTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].lastUsedAt = Date()
    }

    func newTab(url: URL? = nil, isIncognito: Bool = false) {
        var tab = BrowserTabState()
        tab.isIncognito = isIncognito
        if let url { tab.pendingURL = url; tab.urlString = url.absoluteString }
        tabs.append(tab)
        selectedID = tab.id
        saveTabs()
    }

    func closeTab(_ id: UUID) {
        // Closing the last remaining tab does not leave the user stuck:
        // the tab is reset to a fresh start page instead (same behaviour
        // as Chrome closing its last tab).
        if tabs.count == 1, tabs.first?.id == id {
            resetTab(id)
            return
        }
        guard tabs.count > 1 else { return }
        let idx = tabs.firstIndex { $0.id == id } ?? 0
        tabs.removeAll { $0.id == id }
        for gi in groups.indices { groups[gi].tabIDs.removeAll { $0 == id } }
        thumbnails.removeValue(forKey: id)
        webViews[id]?.stopLoading()
        webViews.removeValue(forKey: id)
        loadingPending.removeValue(forKey: id)
        lastHistoryURL.removeValue(forKey: id)
        if selectedID == id { selectedID = tabs[max(0, idx - 1)].id }
        saveTabs()
    }

    /// Replace a tab with a fresh start-page tab (new identity, so the old
    /// WKWebView — and its back/forward history — is discarded for a blank
    /// one). The private/normal mode of the tab is kept.
    func resetTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let incognito = tabs[idx].isIncognito
        webViews[id]?.stopLoading()
        webViews.removeValue(forKey: id)
        thumbnails.removeValue(forKey: id)
        loadingPending.removeValue(forKey: id)
        lastHistoryURL.removeValue(forKey: id)
        for gi in groups.indices { groups[gi].tabIDs.removeAll { $0 == id } }
        var fresh = BrowserTabState()
        fresh.isIncognito = incognito
        tabs[idx] = fresh
        selectedID = fresh.id
        saveTabs()
    }

    func navigateSelected(to url: URL) {
        guard let idx = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        tabs[idx].pendingURL = url
        tabs[idx].urlString = url.absoluteString
        tabs[idx].lastUsedAt = Date()
        saveTabs()
    }

    /// A requested navigation has started (committed, finished or failed):
    /// the pending URL is in WebKit's hands now and must not be re-issued.
    func clearPending(for id: UUID) {
        loadingPending.removeValue(forKey: id)
        guard let idx = tabs.firstIndex(where: { $0.id == id }),
              tabs[idx].pendingURL != nil else { return }
        tabs[idx].pendingURL = nil
    }

    func recordHistoryIfNeeded(tabID: UUID, title: String, urlString: String) {
        guard let tab = tabs.first(where: { $0.id == tabID }), !tab.isIncognito,
              lastHistoryURL[tabID] != urlString else { return }
        lastHistoryURL[tabID] = urlString
        onHistoryRecord?(title, urlString)
    }

    func updateTab(id: UUID, title: String? = nil, urlString: String? = nil, progress: Double? = nil,
                   isLoading: Bool? = nil, canGoBack: Bool? = nil, canGoForward: Bool? = nil) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let title, !title.isEmpty { tabs[idx].title = title }
        if let urlString {
            tabs[idx].urlString = urlString
            tabs[idx].lastUsedAt = Date()
        }
        if let progress { tabs[idx].progress = progress }
        if let isLoading { tabs[idx].isLoading = isLoading }
        if let canGoBack { tabs[idx].canGoBack = canGoBack }
        if let canGoForward { tabs[idx].canGoForward = canGoForward }
        // A committed URL is the moment a tab becomes worth restoring.
        if urlString != nil { saveTabs() }
    }

    func goBack() { webViews[selectedID]?.goBack() }
    func goForward() { webViews[selectedID]?.goForward() }
    /// Back/forward history entries of the selected tab, for the
    /// long-press history menus (Safari/Chrome behaviour).
    func backListItems() -> [WKBackForwardListItem] { webViews[selectedID]?.backForwardList.backList ?? [] }
    func forwardListItems() -> [WKBackForwardListItem] { webViews[selectedID]?.backForwardList.forwardList ?? [] }
    func go(to item: WKBackForwardListItem) { webViews[selectedID]?.go(to: item) }
    func reload() { webViews[selectedID]?.reload() }
    func hardReload() { webViews[selectedID]?.reloadFromOrigin() }
    func stop() { webViews[selectedID]?.stopLoading() }

    // MARK: Per-site zoom + print

    /// Set before a zoom-only settings mutation so the settings-change
    /// handler applies the zoom live instead of reloading the page.
    var skipNextReload = false

    /// Zoom scale for a host: exact clean-host entry wins, then the
    /// www-insensitive / subdomain match used by the other per-site lists.
    func zoomScale(for host: String) -> Double {
        let clean = BrowserSession.cleanHostEntry(host)
        if let exact = latestSettings.siteZoom[clean] { return exact }
        func bare(_ s: String) -> String {
            var h = BrowserSession.cleanHostEntry(s)
            if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
            return h
        }
        let h = bare(host)
        for (key, scale) in latestSettings.siteZoom {
            let b = bare(key)
            if h == b || h.hasSuffix("." + b) { return scale }
        }
        return 1.0
    }

    /// Sends the current chrome height to the bottom-bar lift script, so
    /// a site's own fixed/sticky bottom nav sits above the floating
    /// address pill. Re-applied on every finished navigation (didFinish)
    /// and whenever the inset changes (applyScrollInsets), since a new
    /// document starts with no lift value.
    func pushBottomBarLift(to webView: WKWebView) {
        webView.evaluateJavaScript("window.__mdmSetChromeBottom && window.__mdmSetChromeBottom(\(bottomScrollInset))", completionHandler: nil)
    }

    /// Applies the host's zoom with the CSS `zoom` property WebKit honours.
    /// Re-applied on every finished navigation (didFinish), since a new
    /// document starts at 100%. Clearing the property restores 100%.
    func applyZoom(to webView: WKWebView) {
        guard let host = webView.url?.host, !host.isEmpty else { return }
        let scale = zoomScale(for: host)
        if scale == 1.0 {
            webView.evaluateJavaScript("if(document.body){document.body.style.zoom='';}", completionHandler: nil)
        } else {
            webView.evaluateJavaScript("if(document.body){document.body.style.zoom='\(scale)';}", completionHandler: nil)
        }
    }

    func applyZoomToCurrent() {
        if let webView = webViews[selectedID] { applyZoom(to: webView) }
    }

    /// Prints the current page with the system print sheet (AirPrint /
    /// Save as PDF). WKWebView's own print formatter paginates the page.
    func printCurrentPage() {
        guard let webView = webViews[selectedID] else { return }
        let controller = UIPrintInteractionController.shared
        controller.printFormatter = webView.viewPrintFormatter()
        if UIDevice.current.userInterfaceIdiom == .pad {
            controller.present(from: webView.bounds, in: webView, animated: true, completionHandler: nil)
        } else {
            controller.present(animated: true, completionHandler: nil)
        }
    }

    // MARK: Groups

    @discardableResult
    func createGroup(name: String, colorHex: Int, tabIDs: [UUID] = []) -> BrowserTabGroup {
        let group = BrowserTabGroup(name: name, colorHex: colorHex, tabIDs: tabIDs)
        groups.append(group)
        for tabID in tabIDs { setTabGroup(tabID, groupID: group.id) }
        saveTabs()
        return group
    }

    func setTabGroup(_ tabID: UUID, groupID: UUID?) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let old = tabs[idx].groupID
        tabs[idx].groupID = groupID
        if let old, let gi = groups.firstIndex(where: { $0.id == old }) {
            groups[gi].tabIDs.removeAll { $0 == tabID }
        }
        if let groupID, let gi = groups.firstIndex(where: { $0.id == groupID }),
           !groups[gi].tabIDs.contains(tabID) {
            groups[gi].tabIDs.append(tabID)
        }
        saveTabs()
    }

    func deleteGroup(_ id: UUID) {
        for idx in tabs.indices where tabs[idx].groupID == id { tabs[idx].groupID = nil }
        groups.removeAll { $0.id == id }
        saveTabs()
    }

    func renameGroup(_ id: UUID, name: String, colorHex: Int) {
        guard let gi = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[gi].name = name
        groups[gi].colorHex = colorHex
    }

    func tabs(in group: BrowserTabGroup) -> [BrowserTabState] {
        group.tabIDs.compactMap { id in tabs.first { $0.id == id } }
    }

    func group(of tab: BrowserTabState) -> BrowserTabGroup? {
        guard let gid = tab.groupID else { return nil }
        return groups.first { $0.id == gid }
    }

    // MARK: Thumbnails & page text

    func captureThumbnail(for id: UUID) {
        guard let webView = webViews[id] else { return }
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let image else { return }
            DispatchQueue.main.async { self?.thumbnails[id] = image }
        }
    }

    func captureAllThumbnails() {
        for id in webViews.keys { captureThumbnail(for: id) }
    }

    func extractPageText(completion: @escaping (String) -> Void) {
        guard let webView = webViews[selectedID] else { completion(""); return }
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { result, _ in
            completion((result as? String) ?? "")
        }
    }

    /// Last compiled content-rule lists, kept so compatibility mode can
    /// re-apply them when a tab leaves a compat host without recompiling.
    private var compiledLists: [WKContentRuleList] = []

    func applyRulesAndScripts(settings: BrowserSettings) {
        latestSettings = settings
        AdBlockRules.compile(settings: settings) { [weak self] lists in
            guard let self else { return }
            DispatchQueue.main.async {
                self.compiledLists = lists
                self.blockedStatus = lists.isEmpty ? "AdBlock: off (no rules)" : "AdBlock: on"
                for (_, webView) in self.webViews {
                    self.configureContent(for: webView, settings: settings, lists: lists)
                }
            }
        }
    }

    /// Compatibility hosts (e.g. DRM video sites): content rules and
    /// injected scripts are stripped for these pages, because blockers
    /// and page scripts can break license/key requests and player code.
    func isCompatHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return latestSettings.drmCompatHosts.contains { h in
            let h = h.lowercased()
            return host == h || host.hasSuffix("." + h)
        }
    }

    /// (Re)applies content rules + user scripts to one web view, honouring
    /// compatibility mode for its current host. Called after every
    /// navigation commit, so leaving a compat host restores blocking.
    func refreshCompatibility(for webView: WKWebView) {
        configureContent(for: webView, settings: latestSettings, lists: compiledLists)
    }

    func configureContent(for webView: WKWebView, settings: BrowserSettings, lists: [WKContentRuleList]) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        ucc.removeAllUserScripts()
        // DevTools bridge: always present so console / fetch / XHR
        // activity can be shown in the F12 panel.
        ucc.addUserScript(WKUserScript(
            source: DevToolsBridge.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        // Login capture: always present (even on compat hosts) so
        // save prompts and autofill keep working there.
        ucc.addUserScript(WKUserScript(
            source: PasswordStore.detectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        // Bottom-bar lift: always present so a site's own bottom nav is
        // never hidden behind the floating address pill.
        ucc.addUserScript(WKUserScript(
            source: BrowserSession.bottomBarLiftScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        let compat = isCompatHost(webView.url?.host)
        if !compat {
            for list in lists { ucc.add(list) }
                    for ext in settings.extensions where ext.enabled && ext.runs(on: webView.url) {
                        ucc.addUserScript(WKUserScript(
                            source: ext.source,
                            injectionTime: ext.atDocumentStart ? .atDocumentStart : .atDocumentEnd,
                            forMainFrameOnly: true))
                    }
                    // Background playback: keep the page "visible" so players
                    // do not pause themselves when the app backgrounds.
                    if settings.backgroundPlayback {
                        ucc.addUserScript(WKUserScript(
                            source: BrowserSession.backgroundPlaybackScript,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true))
                    }
                    // In-page PiP button: only a real tap on the page is
                    // accepted by WebKit as the gesture for entering PiP.
                    if settings.pictureInPicture {
                        ucc.addUserScript(WKUserScript(
                            source: BrowserSession.pipButtonScript,
                            injectionTime: .atDocumentEnd,
                            forMainFrameOnly: true))
                    }
                    // Address detection: linkify street addresses to Google
                    // Maps (route + local info) when enabled.
                    if settings.detectAddresses {
                        ucc.addUserScript(WKUserScript(
                            source: BrowserSession.addressDetectorScript,
                            injectionTime: .atDocumentEnd,
                            forMainFrameOnly: true))
                    }
                    // Timer bypass: speed up countdown waits (download
                    // pages, link shorteners) when enabled.
                    if settings.skipTimers {
                        ucc.addUserScript(WKUserScript(
                            source: BrowserSession.timerBypassScript,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true))
                    }
                    // Freeze timers on the listed hosts only.
                    if !settings.freezeTimerHosts.isEmpty {
                        ucc.addUserScript(WKUserScript(
                            source: BrowserSession.timerFreezeScript(hosts: settings.freezeTimerHosts),
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true))
                    }
                    // No-redirect mode: download clicks go straight to the
                    // final link, cross-host popups are dropped.
                    if settings.noRedirects {
                        ucc.addUserScript(WKUserScript(
                            source: BrowserSession.redirectBlockScript,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true))
                    }
                    }
                    webView.allowsLinkPreview = settings.linkPreview
                    if #available(iOS 16.4, *) { webView.isInspectable = settings.webInspector }
                    // Compatibility pages always use the default (mobile
                    // Safari) user agent: a desktop UA can make a video
                    // site serve Widevine instead of FairPlay, which iOS
                    // cannot play at all. Otherwise the Site configuration
                    // for this host wins (desktop mode, then its own
                    // user-agent choice), then the global preset.
                    let pageHost = webView.url?.host
                    if compat {
                        webView.customUserAgent = nil
                    } else if let pageHost, settings.isSiteDesktopMode(for: pageHost) {
                        webView.customUserAgent = UserAgentPreset.mac.uaString
                    } else if let pageHost, let preset = settings.siteUAOverride(for: pageHost) {
                        webView.customUserAgent = preset.uaString
                    } else {
                        webView.customUserAgent = settings.effectiveUserAgent
                    }
                    // Per-site JavaScript switch (Site configuration). The
                    // preference sticks to this tab's web view, so leaving
                    // the host restores the default on the next commit.
                    if let pageHost {
                        webView.configuration.preferences.javaScriptEnabled = !settings.isSiteJavaScriptBlocked(for: pageHost)
                    }
    }

    func findMedia() {
        guard let webView = webViews[selectedID] else { return }
        let js = """
        (() => { const urls = new Set();
          document.querySelectorAll('video, audio').forEach(el => {
            if (el.currentSrc) urls.add(el.currentSrc);
            el.querySelectorAll('source').forEach(s => { if (s.src) urls.add(s.src); });
          });
          document.querySelectorAll('a[href]').forEach(a => {
            if (/\\.(mp4|m3u8|webm|mov|mp3|m4a|zip|pdf|apk|ipa|dmg)(\\?|#|$)/i.test(a.href)) urls.add(a.href);
          });
          return JSON.stringify([...urls]); })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let str = result as? String,
                  let data = str.data(using: .utf8),
                  let strings = try? JSONDecoder().decode([String].self, from: data) else { return }
            self?.onMediaFound?(strings.compactMap(URL.init(string:)))
        }
    }

    // MARK: DevTools logging

    func recordNavigation(tabID: UUID, url: URL, status: Int, responseHeaders: [String: String] = [:]) {
        let entry = DevNetworkEntry(method: "NAV", url: url.absoluteString, status: status, durationMs: 0, source: "navigation", responseHeaders: responseHeaders)
        networkLogs[tabID, default: []].append(entry)
        trimNetworkLog(tabID)
    }

    func appendConsole(tabID: UUID, level: String, text: String) {
        consoleLogs[tabID, default: []].append(DevConsoleEntry(level: level, text: text))
        if consoleLogs[tabID]?.count ?? 0 > 300 {
            consoleLogs[tabID]?.removeFirst((consoleLogs[tabID]?.count ?? 0) - 300)
        }
    }

    func appendNetwork(tabID: UUID, entry: DevNetworkEntry) {
        networkLogs[tabID, default: []].append(entry)
        trimNetworkLog(tabID)
    }

    private func trimNetworkLog(_ tabID: UUID) {
        if networkLogs[tabID]?.count ?? 0 > 300 {
            networkLogs[tabID]?.removeFirst((networkLogs[tabID]?.count ?? 0) - 300)
        }
    }

    func evaluateJS(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        guard let webView = webViews[selectedID] else { completion?(nil, nil); return }
        webView.evaluateJavaScript(script, completionHandler: completion)
    }

    // MARK: Background playback + Picture in Picture

    /// Keeps the page looking "visible" to its own scripts so players
    /// (notably YouTube) do not pause themselves when the app goes to the
    /// background. Only installed while background playback is enabled.
    static let backgroundPlaybackScript = """
    (function() {
      if (window.__mdmBgPlayback) return;
      window.__mdmBgPlayback = true;
      try {
        Object.defineProperty(document, 'hidden', { get: function() { return false; }, configurable: true });
        Object.defineProperty(document, 'visibilityState', { get: function() { return 'visible'; }, configurable: true });
        Object.defineProperty(document, 'webkitHidden', { get: function() { return false; }, configurable: true });
        Object.defineProperty(document, 'webkitVisibilityState', { get: function() { return 'visible'; }, configurable: true });
      } catch (e) {}
      try { document.hasFocus = function() { return true; }; } catch (e2) {}
      document.addEventListener('visibilitychange', function(e) { e.stopImmediatePropagation(); }, true);
      window.addEventListener('pagehide', function(e) { e.stopImmediatePropagation(); }, true);
    })();
    """

    /// Lifts a site's own fixed/sticky bottom bar (its bottom nav) above
    /// the floating browser chrome. Scroll padding alone cannot move
    /// such bars: `position: fixed; bottom: 0` ignores the scroll view's
    /// content inset, so on pages like the LAN inspection app the site
    /// nav ended up behind the address pill. The script watches the DOM
    /// (SPA view switches included) and shifts any bar pinned to the
    /// viewport bottom up by the chrome height Swift sends via
    /// `__mdmSetChromeBottom`. Bars sized by top+height ignore `bottom`,
    /// so those get a translateY nudge instead, preserving any transform
    /// they already had. Full-screen overlays and tall elements are
    /// never touched.
    static let bottomBarLiftScript = """
    (function () {
      var ORIG_BOTTOM = 'data-mdm-orig-bottom';
      var ORIG_TRANSFORM = 'data-mdm-orig-transform';
      var LIFT_PX = 'data-mdm-lift-px';
      var lifted = [];
      var scheduled = false;
      var lastApply = 0;
      function isBottomBar(el) {
        if (!(el instanceof HTMLElement)) return false;
        var cs = window.getComputedStyle(el);
        if (cs.position !== 'fixed' && cs.position !== 'sticky') return false;
        if (cs.display === 'none' || cs.visibility === 'hidden') return false;
        var r = el.getBoundingClientRect();
        var vh = window.innerHeight;
        if (r.height <= 0 || r.height > vh * 0.45) return false;
        if (r.width < 40) return false;
        if (r.top < vh * 0.5) return false;
        if (Math.abs(r.bottom - vh) > 3) return false;
        return true;
      }
      function restore(el) {
        el.style.bottom = el.getAttribute(ORIG_BOTTOM) || '';
        el.style.transform = el.getAttribute(ORIG_TRANSFORM) || '';
        el.removeAttribute(LIFT_PX);
        el.removeAttribute(ORIG_BOTTOM);
        el.removeAttribute(ORIG_TRANSFORM);
      }
      function lift(el, px) {
        if (!el.hasAttribute(ORIG_BOTTOM)) el.setAttribute(ORIG_BOTTOM, el.style.bottom || '');
        if (!el.hasAttribute(ORIG_TRANSFORM)) el.setAttribute(ORIG_TRANSFORM, el.style.transform || '');
        if (el.getAttribute(LIFT_PX) === String(px)) return;
        el.setAttribute(LIFT_PX, String(px));
        var origBottom = el.getAttribute(ORIG_BOTTOM) || '';
        var origTransform = el.getAttribute(ORIG_TRANSFORM) || '';
        if (px > 0) {
          el.style.bottom = px + 'px';
          var moved = Math.abs(el.getBoundingClientRect().bottom - window.innerHeight) > 3;
          el.style.transform = moved ? origTransform : (origTransform + ' translateY(' + (-px) + 'px)');
        } else {
          el.style.bottom = origBottom;
          el.style.transform = origTransform;
        }
      }
      function apply() {
        var px = window.__mdmChromeBottom || 0;
        var root = document.body || document.documentElement;
        if (!root) return;
        var kept = [];
        for (var i = 0; i < lifted.length; i++) {
          var prev = lifted[i];
          if (prev.isConnected && isBottomBar(prev)) { lift(prev, px); kept.push(prev); }
          else restore(prev);
        }
        lifted = kept;
        var all = root.querySelectorAll('*');
        for (var j = 0; j < all.length; j++) {
          var el = all[j];
          if (!isBottomBar(el)) continue;
          if (el.closest('[' + LIFT_PX + ']')) continue;
          if (lifted.indexOf(el) === -1) lifted.push(el);
          lift(el, px);
        }
      }
      function schedule() {
        if (scheduled) return;
        scheduled = true;
        var delay = Math.max(0, 350 - (Date.now() - lastApply));
        setTimeout(function () { scheduled = false; lastApply = Date.now(); apply(); }, delay);
      }
      window.__mdmSetChromeBottom = function (px) {
        window.__mdmChromeBottom = px;
        schedule();
      };
      function watch() {
        schedule();
        if (window.MutationObserver) {
          var mo = new MutationObserver(schedule);
          mo.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class'] });
        }
        window.addEventListener('resize', schedule);
        window.addEventListener('orientationchange', schedule);
      }
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watch);
      else watch();
    })();
    """

    /// Enters Picture in Picture on the playing (or first) <video>.
    /// Returns a JSON diagnostic so a failed attempt on-device says WHY:
    /// video count, paused state, whether the webkit PiP function exists,
    /// what webkitSupportsPresentationMode reported, and whether the
    /// video carried a disablepictureinpicture attribute (removed first).
    static let pipScript = """
    (function(){
      var out = {status: 'unknown', videos: 0, paused: true, hasFn: false, supports: null, disabled: false, area: 0};
      var vids = Array.prototype.slice.call(document.querySelectorAll('video'));
      out.videos = vids.length;
      if (!vids.length) { out.status = 'none'; return JSON.stringify(out); }
      // Pick the video the user is actually watching: the largest visible
      // one, preferring one that is playing. YouTube pages can carry
      // extra hidden/preview <video> elements; taking the first one
      // often targets a video the user never sees.
      function areaOf(el) {
        try { var r = el.getBoundingClientRect(); return Math.max(0, r.width) * Math.max(0, r.height); } catch (e) { return 0; }
      }
      var best = null, bestArea = -1, bestPlaying = null, bestPlayingArea = -1;
      for (var i = 0; i < vids.length; i++) {
        var a = areaOf(vids[i]);
        if (a > bestArea) { bestArea = a; best = vids[i]; }
        if (!vids[i].paused && a > bestPlayingArea) { bestPlayingArea = a; bestPlaying = vids[i]; }
      }
      var v = bestPlaying || best;
      out.area = Math.round(bestPlaying ? bestPlayingArea : bestArea);
      out.paused = !!v.paused;
      out.hasFn = (typeof v.webkitSetPresentationMode === 'function');
      try { out.disabled = v.hasAttribute('disablepictureinpicture'); v.removeAttribute('disablepictureinpicture'); } catch (e) {}
      try { if (typeof v.webkitSupportsPresentationMode === 'function') out.supports = v.webkitSupportsPresentationMode('picture-in-picture'); } catch (e2) {}
      function attempt() {
        try {
          if (typeof v.webkitSetPresentationMode === 'function') {
            v.webkitSetPresentationMode('picture-in-picture');
            return true;
          }
        } catch (e3) {}
        try { if (v.requestPictureInPicture) { var p = v.requestPictureInPicture(); if (p && p.catch) p.catch(function(){}); return true; } } catch (e4) {}
        return false;
      }
      if (!v.paused) {
        var ok = attempt();
        if (!ok) setTimeout(function(){ attempt(); }, 500);
        out.status = ok ? 'pip' : 'unsupported';
        return JSON.stringify(out);
      }
      try { var pr = v.play(); if (pr && pr.catch) pr.catch(function(){}); } catch (e5) {}
      setTimeout(function(){ attempt(); }, 500);
      out.status = 'pip-playing';
      return JSON.stringify(out);
    })()
    """

    /// Picture in Picture button. WebKit only accepts entering PiP in
    /// response to a real tap on the page, so evaluated JavaScript from
    /// the native menu cannot do it reliably: the button lives in the
    /// page itself. On YouTube it is inserted into the player's own
    /// control bar, right before the fullscreen button; on other pages
    /// it floats anchored to the video's top-right corner.
    static let pipButtonScript = """
    (function() {
      if (window.__mdmPiPButton) return;
      window.__mdmPiPButton = true;
      var btn = null, btnMode = '';
      function bestVideo() {
        var vids = document.querySelectorAll('video');
        var best = null, bestArea = 0, bestPlaying = null, bestPlayingArea = 0;
        for (var i = 0; i < vids.length; i++) {
          var v = vids[i];
          if (v.readyState < 2 || v.videoWidth < 200) continue;
          var r = v.getBoundingClientRect();
          var a = Math.max(0, r.width) * Math.max(0, r.height);
          if (a <= 0) continue;
          if (a > bestArea) { bestArea = a; best = v; }
          if (!v.paused && !v.ended && a > bestPlayingArea) { bestPlayingArea = a; bestPlaying = v; }
        }
        return bestPlaying || best;
      }
      function inPiP(v) {
        try { return v.webkitPresentationMode === 'picture-in-picture'; } catch (e) { return false; }
      }
      function enterPiP() {
        var target = bestVideo();
        if (!target) return;
        try { target.removeAttribute('disablepictureinpicture'); } catch (e) {}
        function attempt() {
          try {
            if (typeof target.webkitSetPresentationMode === 'function') {
              target.webkitSetPresentationMode('picture-in-picture');
              return true;
            }
          } catch (e2) {}
          try { if (target.requestPictureInPicture) { var p = target.requestPictureInPicture(); if (p && p.catch) p.catch(function(){}); return true; } } catch (e3) {}
          return false;
        }
        if (target.paused || target.ended) {
          try { var pr = target.play(); if (pr && pr.catch) pr.catch(function(){}); } catch (e4) {}
          setTimeout(function(){ attempt(); }, 500);
        } else {
          if (!attempt()) setTimeout(function(){ attempt(); }, 500);
        }
      }
      function ytControls() {
        var fs = document.querySelector('.ytp-fullscreen-button');
        if (fs && fs.parentElement) return { bar: fs.parentElement, fsBtn: fs };
        var rc = document.querySelector('.ytp-right-controls');
        if (rc) return { bar: rc, fsBtn: null };
        return null;
      }
      function createButton() {
        var b = document.createElement('button');
        b.setAttribute('aria-label', 'Picture in Picture');
        b.setAttribute('title', 'Picture in Picture');
        b.addEventListener('click', function(ev) {
          ev.preventDefault(); ev.stopPropagation();
          enterPiP();
        });
        return b;
      }
      function styleForChrome(b) {
        b.className = 'ytp-button';
        b.innerHTML = '<svg width="24" height="24" viewBox="0 0 24 24" fill="#fff"><path d="M19 11h-8v6h8v-6zm4 8V4.98C23 3.88 22.1 3 21 3H3c-1.1 0-2 .88-2 1.98V19c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2zm-2 .02H3V4.97h18v14.05z"/></svg>';
        b.style.cssText = 'display:flex;align-items:center;justify-content:center;background:transparent;border:0;padding:0;cursor:pointer;';
      }
      function styleForFloat(b) {
        b.className = '';
        b.textContent = 'PiP';
        b.style.cssText = 'position:fixed;z-index:2147483647;padding:8px 14px;border:0;border-radius:999px;background:rgba(0,0,0,0.65);color:#fff;font:600 13px -apple-system,system-ui,sans-serif;box-shadow:0 2px 10px rgba(0,0,0,0.35);';
      }
      function refresh() {
        var v = bestVideo();
        var show = !!(v && !v.ended && !inPiP(v));
        if (!show) { if (btn) btn.style.display = 'none'; return; }
        var yt = ytControls();
        if (yt) {
          if (!btn || !btn.isConnected || btnMode !== 'chrome') {
            btn = createButton();
            styleForChrome(btn);
            btnMode = 'chrome';
          }
          if (btn.parentNode !== yt.bar) {
            if (yt.fsBtn) yt.bar.insertBefore(btn, yt.fsBtn);
            else yt.bar.appendChild(btn);
          }
          btn.style.display = '';
        } else {
          if (document.webkitFullscreenElement) { if (btn) btn.style.display = 'none'; return; }
          if (!btn || !btn.isConnected || btnMode !== 'float') {
            btn = createButton();
            styleForFloat(btn);
            btnMode = 'float';
          }
          if (btn.parentNode !== document.documentElement) document.documentElement.appendChild(btn);
          var r = v.getBoundingClientRect();
          btn.style.left = Math.max(8, r.right - 64) + 'px';
          btn.style.top = Math.max(8, r.top + 10) + 'px';
          btn.style.display = '';
        }
      }
      document.addEventListener('play', refresh, true);
      document.addEventListener('pause', refresh, true);
      document.addEventListener('webkitpresentationmodechanged', refresh, true);
      window.addEventListener('scroll', refresh, true);
      window.addEventListener('resize', refresh);
      setInterval(refresh, 1000);
      refresh();
    })()
    """

    /// Address detection (heuristic): street addresses ("Jl. …", "Jalan …"
    /// with a number) become links to a Google Maps search, where route
    /// and local info are shown. Runs on an interval so late-loaded
    /// content is caught too; already-linked text is left alone.
    static let addressDetectorScript = """
    (function() {
      if (window.__mdmAddrDetect) return;
      window.__mdmAddrDetect = true;
      var ADDR_RE = /\\b(Jl\\.?|Jalan)\\s+[A-ZÀ-ÿ0-9][^<\\n,;]{3,60}/g;
      function scan() {
        if (!document.body) return;
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var nodes = [], checked = 0;
        while (walker.nextNode() && checked < 400) { nodes.push(walker.currentNode); checked++; }
        for (var i = 0; i < nodes.length; i++) {
          var node = nodes[i];
          var parent = node.parentElement;
          if (!parent) continue;
          var tag = parent.tagName;
          if (tag === 'A' || tag === 'SCRIPT' || tag === 'STYLE' || tag === 'TEXTAREA' || tag === 'INPUT' || tag === 'BUTTON' || tag === 'SELECT') continue;
          if (parent.closest && parent.closest('a, .__mdmAddr')) continue;
          var text = node.nodeValue || '';
          ADDR_RE.lastIndex = 0;
          var m = ADDR_RE.exec(text);
          if (!m || !/\\d/.test(m[0])) continue;
          var match = m[0].replace(/\\s+$/, '');
          var rest = node.splitText(m.index);
          rest.splitText(match.length);
          var link = document.createElement('a');
          link.textContent = match;
          link.href = 'https://www.google.com/maps/search/?api=1&query=' + encodeURIComponent(match);
          link.className = '__mdmAddr';
          link.style.cssText = 'text-decoration:underline dotted;';
          rest.parentNode.replaceChild(link, rest);
        }
      }
      setTimeout(scan, 800);
      setInterval(scan, 3000);
    })()
    """

    /// Timer bypass (best effort, opt-in): countdown waits on download /
    /// link-shortener pages are usually plain setTimeout/setInterval
    /// counters in page JavaScript. This runs at document start, before
    /// page scripts, and divides every timer delay by 50, so a 10-second
    /// countdown finishes in ~0.2s; a scanner also re-enables download
    /// buttons that a countdown left disabled or hidden. It cannot beat
    /// waits enforced server-side (the link is generated only after the
    /// server's own delay) or human-verification gates like Cloudflare.
    static let timerBypassScript = """
    (function() {
      if (window.__mdmTimerBypass) return;
      window.__mdmTimerBypass = true;
      var SPEED = 50;
      var nativeSetTimeout = window.setTimeout.bind(window);
      var nativeSetInterval = window.setInterval.bind(window);
      function scaleDelay(d) {
        d = Number(d) || 0;
        if (d <= 0) return d;
        return Math.max(0, Math.floor(d / SPEED));
      }
      window.setTimeout = function(fn, delay) {
        // Freeze wins over bypass: if the freeze script ran (before or
        // after this one), page timers must never fire at all.
        if (window.__mdmTimerFrozen) return 0;
        var args = Array.prototype.slice.call(arguments, 2);
        return nativeSetTimeout.apply(window, [fn, scaleDelay(delay)].concat(args));
      };
      window.setInterval = function(fn, delay) {
        if (window.__mdmTimerFrozen) return 0;
        var args = Array.prototype.slice.call(arguments, 2);
        return nativeSetInterval.apply(window, [fn, scaleDelay(delay)].concat(args));
      };
      var DOWNLOAD_RE = /(download|unduh|get\\s*link|continue|lanjutkan|free\\s*download)/i;
      var COUNT_RE = /(\\d+)\\s*(seconds?|secs?|detik)/i;
      var WAIT_RE = /please\\s*wait|mohon\\s*tunggu|waiting|preparing/i;
      function isHidden(el) {
        var s = window.getComputedStyle(el);
        return s.display === 'none' || s.visibility === 'hidden';
      }
      function enable(el) {
        try {
          el.removeAttribute('disabled');
          el.removeAttribute('aria-disabled');
          el.classList.remove('disabled');
          el.style.pointerEvents = 'auto';
          el.style.opacity = '';
          if (isHidden(el)) el.style.setProperty('display', 'inline-block', 'important');
        } catch (e) {}
      }
      function nearbyText(el) {
        var text = '';
        var node = el;
        for (var level = 0; level < 2 && node; level++) {
          node = node.parentElement;
          if (!node) break;
          text += ' ' + (node.innerText || '');
        }
        return text;
      }
      function scan() {
        // Frozen site: do not re-enable timer-gated buttons either —
        // the bypass scanner must stay out of the way entirely.
        if (window.__mdmTimerFrozen) return;
        try {
          if (!document.body) return;
          var els = document.querySelectorAll('a, button, input[type="button"], input[type="submit"]');
          for (var i = 0; i < els.length; i++) {
            var el = els[i];
            var text = (el.innerText || el.value || el.getAttribute('aria-label') || '');
            if (!DOWNLOAD_RE.test(text)) continue;
            var gated = el.disabled || el.getAttribute('aria-disabled') === 'true' ||
              el.classList.contains('disabled') || isHidden(el);
            if (!gated) continue;
            var near = nearbyText(el);
            if (COUNT_RE.test(text) || COUNT_RE.test(near) || WAIT_RE.test(near)) enable(el);
          }
        } catch (e) {}
      }
      nativeSetInterval(scan, 500);
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', scan);
      } else {
        scan();
      }
    })()
    """

    /// Freeze timers, per site (opt-in, document start, before page
    /// scripts run): on a listed host, setTimeout/setInterval are
    /// replaced with no-ops, so countdown and trial timers never tick
    /// and the page's timer-driven state stays frozen. Unlike the
    /// timer bypass (which speeds timers up), this stops them. It only
    /// affects timers in page JavaScript — waits enforced server-side
    /// or by human-verification gates are untouched, and pages whose
    /// own rendering depends on timers may look stuck; that is the
    /// point of freezing, so it is per-site only.
    /// Normalises a user-typed host entry ("https://www.contoh.com/x",
    /// "WWW.Contoh.COM:8080") to a bare lowercase host ("contoh.com"),
    /// so freeze/exception lists match regardless of how the host was
    /// entered or whether the page is on www. or a subdomain.
    static func cleanHostEntry(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = h.range(of: "://") { h = String(h[range.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        if let q = h.firstIndex(of: "?") { h = String(h[..<q]) }
        if let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    static func timerFreezeScript(hosts: [String]) -> String {
        // Only hostname-safe characters reach the script, so a crafted
        // host entry cannot break out of the embedded JS string.
        let list = hosts.map { BrowserSession.cleanHostEntry($0) }
            .filter { !$0.isEmpty }
            .map { host in
                "\"" + host.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" } + "\""
            }.joined(separator: ",")
        return """
        (function() {
          if (window.__mdmTimerFrozen) return;
          var HOSTS = [\(list)];
          var host = (location.hostname || '').toLowerCase();
          var bare = host.replace(/^www\\./, '');
          function norm(h) { return h.replace(/^www\\./, ''); }
          var match = HOSTS.some(function(h) {
            h = norm(h);
            return bare === h || bare.endsWith('.' + h);
          });
          if (!match) return;
          window.__mdmTimerFrozen = true;
          window.setTimeout = function() { return 0; };
          window.setInterval = function() { return 0; };
        })()
        """
    }

    /// No-redirect mode: clicks on download links go straight to the
    /// link's own URL instead of through the page's click handlers
    /// (which open ad popups and never follow the link), and cross-host
    /// window.open calls are dropped. An overlay scan unblocks download
    /// buttons covered by invisible overlay elements (the sfile.co trace
    /// showed the button covered by an overlay whose click opened a
    /// Shopee affiliate popup while the real download never started).
    /// Same-host popups and ordinary tapped links are untouched.
    static let redirectBlockScript = """
    (function() {
      if (window.__mdmNoRedirect) return;
      window.__mdmNoRedirect = true;
      var FILE_EXT = /\\.(zip|rar|7z|apk|ipa|dmg|exe|msi|pkg|iso|torrent|mp4|mkv|mov|mp3|flac|epub)(\\?|#|$)/i;
      function resolve(href) {
        try { return new URL(href, location.href); } catch (e) { return null; }
      }
      function isFileURL(u) { return FILE_EXT.test(u.pathname); }
      function isCrossHost(u) { return u.hostname !== location.hostname; }
      var nativeOpen = window.open.bind(window);
      window.open = function(url, target, features) {
        if (url == null || url === '') return null;
        var u = resolve(String(url));
        if (!u) return null;
        if (isCrossHost(u)) {
          if (isFileURL(u)) { location.assign(u.href); }
          return null;
        }
        return nativeOpen.apply(window, arguments);
      };
      document.addEventListener('click', function(ev) {
        var t = ev.target;
        var a = t && t.closest ? t.closest('a[href]') : null;
        if (!a) return;
        var href = a.getAttribute('href');
        if (!href || href.charAt(0) === '#') return;
        var u = resolve(href);
        if (!u) return;
        var text = a.innerText || '';
        var isDownload = isFileURL(u) || /\\/download\\//i.test(u.pathname) ||
          a.hasAttribute('download') || /download|unduh/i.test(text);
        if (isDownload) {
          ev.preventDefault();
          ev.stopPropagation();
          ev.stopImmediatePropagation();
          location.assign(u.href);
          return;
        }
        if (a.target === '_blank' && isCrossHost(u)) {
          ev.preventDefault();
          ev.stopPropagation();
          ev.stopImmediatePropagation();
          location.assign(u.href);
        }
      }, true);
      function unblockOverlays() {
        try {
          if (!document.body) return;
          var els = document.querySelectorAll('a[href], button');
          for (var i = 0; i < els.length; i++) {
            var el = els[i];
            var text = el.innerText || '';
            if (!/download|unduh/i.test(text)) continue;
            var r = el.getBoundingClientRect();
            if (r.width === 0 || r.height === 0) continue;
            var top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
            if (!top || top === el || el.contains(top)) continue;
            var node = top, isAncestor = false;
            while (node) { if (node === el) { isAncestor = true; break; } node = node.parentElement; }
            if (isAncestor) continue;
            var topText = (top.innerText || '').trim();
            var cls = (top.id || '') + ' ' + (top.className || '');
            if (topText.length === 0 || /ad|ads|promo|banner|overlay|popup|affiliate/i.test(cls)) {
              top.style.pointerEvents = 'none';
            }
          }
        } catch (e) {}
      }
      setInterval(unblockOverlays, 600);
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', unblockOverlays);
      } else {
        unblockOverlays();
      }
    })()
    """

    /// Reader-mode extraction (best effort): the <article> element, or
    /// the container with the most paragraph text. Scripts, chrome and
    /// inline event handlers are stripped; images are dropped.
    static let readabilityScript = """
    (function() {
      function clean(el) {
        var bad = el.querySelectorAll('script,style,nav,header,footer,aside,form,noscript,iframe,button,select,input');
        for (var i = 0; i < bad.length; i++) { bad[i].remove(); }
        var all = el.querySelectorAll('*');
        for (var j = 0; j < all.length; j++) {
          var attrs = all[j].attributes;
          for (var k = attrs.length - 1; k >= 0; k--) {
            if (attrs[k].name.slice(0, 2) === 'on') all[j].removeAttribute(attrs[k].name);
          }
        }
      }
      var title = document.title || '';
      var root = document.querySelector('article');
      if (!root) {
        var best = null, bestScore = 0;
        var cands = document.querySelectorAll('div,section,main');
        for (var i = 0; i < cands.length; i++) {
          var ps = cands[i].querySelectorAll('p');
          var len = 0;
          for (var j = 0; j < ps.length; j++) { len += (ps[j].innerText || '').trim().length; }
          if (ps.length >= 2 && len > bestScore) { bestScore = len; best = cands[i]; }
        }
        root = best || document.body;
      }
      var clone = root.cloneNode(true);
      clean(clone);
      var imgs = clone.querySelectorAll('img');
      for (var n = 0; n < imgs.length; n++) { imgs[n].remove(); }
      return JSON.stringify({title: title, html: (clone.innerHTML || '').slice(0, 200000)});
    })()
    """

    func applyMediaPlaybackSettings(_ settings: BrowserSettings) {
        MediaPlaybackAudio.apply(
            backgroundPlayback: settings.backgroundPlayback,
            pictureInPicture: settings.pictureInPicture)
    }

    func fetchArticle(completion: @escaping (String, String) -> Void) {
        evaluateJS(Self.readabilityScript) { result, _ in
            guard let str = result as? String, let data = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion("", "")
                return
            }
            completion(json["title"] as? String ?? "", json["html"] as? String ?? "")
        }
    }

    /// Quote a Swift string as a JavaScript string literal (JSON encoding).
    static func jsQuoted(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let json = String(data: data, encoding: .utf8), json.count >= 2 else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    /// Page translation via Google's in-page Translate element: the page
    /// itself is translated in place, the URL stays the same, and the
    /// browser's scripts keep working. Page text goes through Google's
    /// servers. Reloading the tab restores the original page.
    static func translateScript(lang: String) -> String {
        """
        (function() {
          if (window.__mdmTranslateOn) return 'already';
          window.__mdmTranslateOn = true;
          var el = document.getElementById('google_translate_element');
          if (!el) {
            el = document.createElement('div');
            el.id = 'google_translate_element';
            el.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#fff;border-bottom:1px solid #ccc;padding:4px 8px;font:12px sans-serif;';
            document.body.appendChild(el);
          }
          window.googleTranslateElementInit = function() {
            try {
              new google.translate.TranslateElement({pageLanguage: 'auto', includedLanguages: 'id,en,ms,zh-CN,zh-TW,ja,ko,ar,nl,es,fr,de,pt,ru,hi,th,vi', layout: google.translate.TranslateElement.InlineLayout.SIMPLE}, 'google_translate_element');
            } catch (e) {}
            var tries = 0;
            var iv = setInterval(function() {
              var combo = document.querySelector('.goog-te-combo');
              if (combo) {
                combo.value = '\(lang)';
                try { combo.dispatchEvent(new Event('change')); } catch (e2) {}
                clearInterval(iv);
              } else if (++tries > 30) { clearInterval(iv); }
            }, 300);
          };
          var s = document.createElement('script');
          s.src = 'https://translate.google.com/translate_a/element.js?cb=googleTranslateElementInit';
          document.head.appendChild(s);
          return 'ok';
        })()
        """
    }

    func findInPage(query: String, backwards: Bool, completion: ((Bool) -> Void)? = nil) {
        let q = Self.jsQuoted(query)
        evaluateJS("window.find(\(q), false, \(backwards ? "true" : "false"), true)") { result, _ in
            completion?(result as? Bool ?? false)
        }
    }

    func countFindMatches(query: String, completion: @escaping (Int) -> Void) {
        let q = Self.jsQuoted(query)
        let script = "(function(q){ if(!q) return 0; var t=(document.body?document.body.innerText:'')||''; var n=0,i=0; var l=q.toLowerCase(); var s=t.toLowerCase(); while((i=s.indexOf(l,i))!==-1){n++; i+=l.length;} return n; })(\(q))"
        evaluateJS(script) { result, _ in
            completion((result as? NSNumber)?.intValue ?? 0)
        }
    }

    func clearFindSelection() {
        evaluateJS("try { window.getSelection().removeAllRanges(); } catch (e) {}")
    }
}

// MARK: - Media audio session (background playback + PiP)
//
// WKWebView media only keeps playing after the app backgrounds when the
// app holds the audio background mode (INFOPLIST_KEY_UIBackgroundModes)
// AND the shared audio session is a playback session. WebKit respects
// the app's session; .mixWithOthers keeps other apps' audio playing too
// instead of hijacking it when the browser opens.

enum MediaPlaybackAudio {
    static func apply(backgroundPlayback: Bool, pictureInPicture: Bool) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            if backgroundPlayback || pictureInPicture {
                try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try audioSession.setActive(true)
            } else {
                try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
            }
        } catch {
            // Best-effort: foreground playback still works without it.
        }
    }
}

// MARK: - WKWebView wrapper

struct BrowserWebView: UIViewRepresentable {
    @ObservedObject var session: BrowserSession
    var tabID: UUID
    var settings: BrowserSettings

    func makeCoordinator() -> Coordinator { Coordinator(session: session, tabID: tabID) }

    func makeUIView(context: Context) -> WKWebView {
        if let existing = session.webViews[tabID] {
            // A new coordinator was created for this tab (e.g. after a tab
            // switch, since only the selected tab's view is in the
            // hierarchy): re-attach the state observations, or progress /
            // loading / title / URL stop updating and the stop button
            // freezes on the X icon.
            context.coordinator.observe(webView: existing)
            return existing
        }
        let isIncognito = session.tabs.first(where: { $0.id == tabID })?.isIncognito ?? false
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = settings.pictureInPicture
        if isIncognito {
            // Private tabs: nothing is persisted — separate process pool and
            // a non-persistent data store (no cookies, cache or history kept).
            config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
            config.processPool = WKProcessPool()
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = settings.gestureEdgeSwipe
        // Pull down from the top to reload, Safari-style (toggleable).
        if settings.gesturePullRefresh {
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.didPullToRefresh(_:)), for: .valueChanged)
            webView.scrollView.refreshControl = refreshControl
        }
        // DevTools bridge: message handler + document-start script, added
        // before the first load so early console/network activity is seen.
        config.userContentController.add(context.coordinator, name: "mdmDevTools")
        // Login capture: handler + document-end script, added before the
        // first load so login forms are seen (configureContent re-adds
        // the script after every navigation).
        config.userContentController.add(context.coordinator, name: "mdmLogin")
        config.userContentController.addUserScript(WKUserScript(
            source: PasswordStore.detectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(
            source: BrowserSession.bottomBarLiftScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(
            source: DevToolsBridge.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        // Background playback: keep the page "visible" so players do not
        // pause themselves when the app backgrounds.
        if settings.backgroundPlayback {
            config.userContentController.addUserScript(WKUserScript(
                source: BrowserSession.backgroundPlaybackScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        }
        webView.allowsLinkPreview = settings.linkPreview
        if #available(iOS 16.4, *) { webView.isInspectable = settings.webInspector }
        session.webViews[tabID] = webView
        // Apply rules/scripts once created (compile is async; reload after apply).
        session.applyRulesAndScripts(settings: settings)
        if let pending = session.tabs.first(where: { $0.id == tabID })?.pendingURL {
            session.loadingPending[tabID] = pending
            webView.load(URLRequest(url: pending))
        }
        context.coordinator.observe(webView: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        session.applyScrollInsets()
        // Gesture toggles apply live (Reynard-style individual toggles).
        webView.allowsBackForwardNavigationGestures = settings.gestureEdgeSwipe
        if settings.gesturePullRefresh {
            if webView.scrollView.refreshControl == nil {
                let refreshControl = UIRefreshControl()
                refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.didPullToRefresh(_:)), for: .valueChanged)
                webView.scrollView.refreshControl = refreshControl
            }
        } else {
            webView.scrollView.refreshControl = nil
        }
        guard let tab = session.tabs.first(where: { $0.id == tabID }),
              let pending = tab.pendingURL else { return }
        // Issue each pending URL exactly once. Comparing webView.url
        // against pending is unreliable (servers redirect, WebKit
        // normalises bare domains with a trailing slash), and re-issuing
        // load() on every state tick restarts the load forever.
        if session.loadingPending[tabID] != pending {
            session.loadingPending[tabID] = pending
            webView.load(URLRequest(url: pending))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let session: BrowserSession
        let tabID: UUID
        private var observations: [NSKeyValueObservation] = []
        private weak var webView: WKWebView?
        init(session: BrowserSession, tabID: UUID) { self.session = session; self.tabID = tabID }

        @objc func didPullToRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
        }

        func observe(webView: WKWebView) {
            self.webView = webView
            session.applyScrollInsets()
            // Correct any stale tab state left by a previous coordinator
            // (e.g. isLoading stuck true) right away.
            session.updateTab(id: tabID, title: webView.title, urlString: webView.url?.absoluteString,
                              progress: webView.estimatedProgress, isLoading: webView.isLoading,
                              canGoBack: webView.canGoBack, canGoForward: webView.canGoForward)
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                    guard let self else { return }
                    self.session.updateTab(id: self.tabID, progress: wv.estimatedProgress)
                },
                webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                    guard let self else { return }
                    self.session.updateTab(id: self.tabID, title: wv.title)
                },
                webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                    guard let self, let url = wv.url else { return }
                    self.session.updateTab(id: self.tabID, urlString: url.absoluteString,
                                           canGoBack: wv.canGoBack, canGoForward: wv.canGoForward)
                    let urlString = url.absoluteString
                    if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
                        self.session.recordHistoryIfNeeded(tabID: self.tabID, title: wv.title ?? "", urlString: urlString)
                    }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                    guard let self else { return }
                    if !wv.isLoading { wv.scrollView.refreshControl?.endRefreshing() }
                    self.session.updateTab(id: self.tabID, isLoading: wv.isLoading,
                                           canGoBack: wv.canGoBack, canGoForward: wv.canGoForward)
                },
            ]
        }

        // A requested navigation has started or ended: the pending URL is
        // in WebKit's hands now and must not be re-issued.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            session.clearPending(for: tabID)
            session.refreshCompatibility(for: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            session.clearPending(for: tabID)
            session.refreshCompatibility(for: webView)
            session.applyZoom(to: webView)
            session.pushBottomBarLift(to: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            session.clearPending(for: tabID)
        }

        // File URLs (same extension set as download capture below), used
        // by the no-redirect rules so real downloads are never dropped.
        private static let downloadExtensions: Set<String> = ["zip", "rar", "7z", "apk", "ipa", "dmg", "exe", "msi", "pkg", "iso", "torrent", "mp4", "mkv", "mov", "mp3", "flac", "epub"]

        private static func isFileURL(_ url: URL) -> Bool {
            downloadExtensions.contains(url.pathExtension.lowercased())
        }

        /// Local/LAN hosts are exempt from HTTPS-Only upgrades.
        private static func isLocalHost(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            if host == "localhost" || host.hasSuffix(".local") { return true }
            if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
            if host.hasPrefix("172.") {
                let second = host.split(separator: ".").dropFirst().first.flatMap { Int($0) } ?? -1
                if (16...31).contains(second) { return true }
            }
            return false
        }

        // Download capture: attachment responses and non-web files go to the MDM queue.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let downloadExts = ["zip", "rar", "7z", "apk", "ipa", "dmg", "exe", "msi", "pkg", "iso", "torrent", "mp4", "mkv", "mov", "mp3", "flac", "epub"]
            var isDownload = false
            if let http = navigationResponse.response as? HTTPURLResponse,
               let disp = http.value(forHTTPHeaderField: "Content-Disposition"),
               disp.lowercased().contains("attachment") {
                isDownload = true
            }
            let mime = navigationResponse.response.mimeType ?? ""
            if let url = navigationResponse.response.url {
                let http = navigationResponse.response as? HTTPURLResponse
                var headers: [String: String] = [:]
                if let fields = http?.allHeaderFields {
                    for (k, v) in fields { headers[String(describing: k)] = String(describing: v) }
                }
                session.recordNavigation(tabID: tabID, url: url, status: http?.statusCode ?? 0, responseHeaders: headers)
            }
            if let url = navigationResponse.response.url {
                let ext = url.pathExtension.lowercased()
                if downloadExts.contains(ext) && !mime.hasPrefix("text/html") { isDownload = true }
            }
            // Servers that hide the filename (e.g. /download?id=123) but serve
            // a binary payload: treat octet-stream and archive/executable
            // payloads as downloads too, so they land in the MDM queue
            // automatically instead of opening a blank page.
            let downloadMimes = ["application/octet-stream", "application/zip",
                "application/x-rar-compressed", "application/x-7z-compressed",
                "application/x-msdownload", "application/x-apple-diskimage",
                "application/x-iso9660-image", "application/x-bittorrent",
                "application/x-executable"]
            if downloadMimes.contains(mime) { isDownload = true }
            if isDownload, let url = navigationResponse.response.url {
                session.onDownloadCaptured?(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // HTTPS-Only mode (Firefox): upgrade http:// main-frame
            // navigations to https://; local/LAN hosts are exempt.
            if session.latestSettings.httpsOnly,
               let url = navigationAction.request.url,
               url.scheme == "http",
               navigationAction.targetFrame?.isMainFrame == true,
               !Self.isLocalHost(url) {
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                comps?.scheme = "https"
                if let https = comps?.url {
                    decisionHandler(.cancel)
                    webView.load(URLRequest(url: https))
                    return
                }
            }
            // No-redirect mode: script-opened windows (window.open,
            // popups) to another host are dropped outright instead of
            // taking over this tab; file URLs still load so download
            // capture catches them. Tapped links (linkActivated, e.g.
            // long-press "Open in new tab") keep the existing same-tab
            // behaviour.
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                if session.latestSettings.noRedirects,
                   navigationAction.navigationType != .linkActivated,
                   url.host != webView.url?.host,
                   !Self.isFileURL(url) {
                    decisionHandler(.cancel)
                    return
                }
                webView.load(URLRequest(url: url))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // No-redirect mode drops cross-host script-opened windows
            // outright (the in-page script covers tapped links).
            if session.latestSettings.noRedirects,
               navigationAction.navigationType != .linkActivated,
               let url = navigationAction.request.url,
               url.host != webView.url?.host,
               !Self.isFileURL(url) {
                return nil
            }
            // Popup blocker: script-opened windows (window.open) are
            // dropped when enabled; links the user tapped (linkActivated)
            // still open in this tab.
            if navigationAction.navigationType != .linkActivated, session.latestSettings.blockPopups {
                return nil
            }
            if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
            return nil
        }

        // Link long-press menu (Safari/Chrome parity): open, open in a
        // new (or private) tab, download the linked file, copy/share the
        // link, bookmark, reading list. Returning nil for non-link
        // elements keeps WebKit's built-in menu (images, etc.).
        func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                     completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
            guard let linkURL = elementInfo.linkURL else { completionHandler(nil); return }
            let configuration = UIContextMenuConfiguration(identifier: linkURL as NSURL, previewProvider: nil) { [weak self] _ in
                guard let self else { return UIMenu(children: []) }
                let open = UIAction(title: "Buka", image: UIImage(systemName: "arrow.up.forward.square")) { _ in
                    self.session.select(self.tabID)
                    self.session.navigateSelected(to: linkURL)
                }
                let newTab = UIAction(title: "Buka di Tab Baru", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    self.session.newTab(url: linkURL)
                }
                let privateTab = UIAction(title: "Buka di Tab Pribadi Baru", image: UIImage(systemName: "eye.slash")) { _ in
                    self.session.newTab(url: linkURL, isIncognito: true)
                }
                let download = UIAction(title: "Unduh File Tertaut", image: UIImage(systemName: "arrow.down.circle")) { _ in
                    self.session.onDownloadCaptured?(linkURL)
                }
                let copy = UIAction(title: "Salin Link", image: UIImage(systemName: "link")) { _ in
                    UIPasteboard.general.url = linkURL
                }
                let share = UIAction(title: "Bagikan…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    Self.presentShareSheet(url: linkURL, sourceView: webView)
                }
                let bookmark = UIAction(title: "Tambah ke Bookmark", image: UIImage(systemName: "bookmark")) { _ in
                    self.session.onBookmarkAdd?(linkURL.absoluteString, webView.title ?? "")
                }
                let reading = UIAction(title: "Tambah ke Daftar Bacaan", image: UIImage(systemName: "eyeglasses")) { _ in
                    self.session.onReadingListAdd?(linkURL.absoluteString, webView.title ?? "")
                }
                return UIMenu(title: linkURL.absoluteString, children: [open, newTab, privateTab, download, copy, share, bookmark, reading])
            }
            completionHandler(configuration)
        }

        /// Shares a URL from UIKit land (the context menu has no SwiftUI
        /// ShareLink): presents on the key window's root view controller.
        private static func presentShareSheet(url: URL, sourceView: UIView) {
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = sourceView
                popover.sourceRect = CGRect(x: sourceView.bounds.midX, y: sourceView.bounds.midY, width: 1, height: 1)
            }
            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            keyWindow?.rootViewController?.present(sheet, animated: true)
        }

        // Login-form bridge messages (save prompts, autofill offers).
        // Private tabs never save or fill logins.
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "mdmLogin" {
                guard let body = message.body as? [String: Any] else { return }
                if session.tabs.first(where: { $0.id == tabID })?.isIncognito == true { return }
                session.onLoginMessage?(tabID, body)
                return
            }
            guard message.name == "mdmDevTools",
                  let body = message.body as? [String: Any] else { return }
            session.onDevToolsMessage?(tabID, body)
        }
    }
}

// MARK: - Favicon (Google's favicon service, globe fallback)

struct FaviconView: View {
    var host: String
    var size: CGFloat = 28

    var body: some View {
        if host.isEmpty {
            Image(systemName: "globe")
                .font(.system(size: size * 0.6))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        } else {
            AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        }
    }
}

// MARK: - Shared address-input resolution (URL vs. search query)

func resolveAddressInput(_ raw: String, engine: String) -> URL? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let lower = text.lowercased()
    let looksLikeHost = text.contains(".") || lower.hasPrefix("localhost")
    if text.contains(" ") || (!looksLikeHost && URL(string: text)?.scheme == nil) {
        return SearchEngine.searchURL(for: engine, query: text)
    }
    if text.hasPrefix("http://") || text.hasPrefix("https://") {
        return URL(string: text)
    }
    // Bare IP literals (10.128.4.218:5000), localhost and .local hosts are
    // plain-HTTP LAN servers — forcing https:// breaks them outright, so
    // they get http://. Everything else keeps the https:// default.
    let hostPart = lower.split(separator: "/", maxSplits: 1).first ?? Substring(lower)
    let host = hostPart.split(separator: ":").first.map(String.init) ?? ""
    let octets = host.split(separator: ".")
    let isIPLiteral = octets.count == 4 && octets.allSatisfy { Int($0) != nil }
    let isLocal = isIPLiteral || host == "localhost" || host.hasSuffix(".local")
    return URL(string: (isLocal ? "http://" : "https://") + text)
}

// MARK: - Browser UI (Safari-style floating navbar + Chrome-style overview)

struct BrowserView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    /// When the browser lives in the bottom tab bar, "Kembali ke
    /// Download" switches to the Downloads tab instead of dismissing.
    var onExitToDownloads: (() -> Void)? = nil
    @StateObject private var session = BrowserSession()
    @State private var addressDraft = ""
    @State private var isEditingAddress = false
    @State private var showingAdBlock = false
    @State private var showingSiteInfo = false
    @State private var showingCookies = false
    @State private var showingSiteConfig = false
    @State private var showingMedia = false
    @State private var showingOverview = false
    @State private var showingAI = false
    @State private var showingDevTools = false
    @State private var showingHistory = false
    @State private var showingBookmarks = false
    @State private var showingBackHistory = false
    @State private var showingForwardHistory = false
    @State private var showingClearData = false
    @State private var showingReader = false
    @State private var readerTitle = ""
    @State private var readerHTML = ""
    @State private var showingTranslate = false
    @State private var translatedTab: UUID?
    @State private var showingFind = false
    @State private var findQuery = ""
    @State private var findCount = 0
    @State private var showingReadingList = false
    @State private var showingMenuSheet = false
    @State private var showingSettingsSheet = false
    @State private var menuPage = 0

    // MARK: - Via-style bottom-sheet menu (icon grid, swipeable pages)

    private struct MenuGridItem: Identifiable {
        let id = UUID()
        let label: String
        let systemImage: String
        var isEnabled: Bool = true
        var isDestructive: Bool = false
        var isActive: Bool = false
        /// Runs without dismissing the sheet (used by the "Alat" page-switch cell).
        var keepsSheetOpen: Bool = false
        let action: () -> Void
    }

    private var menuSheet: some View {
        VStack(spacing: 0) {
            TabView(selection: $menuPage) {
                ForEach(menuPages.indices, id: \.self) { pageIndex in
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 18) {
                        ForEach(menuPages[pageIndex]) { item in menuGridCell(item) }
                    }
                    .padding(.horizontal, 10)
                    // Pin the grid to the top of the page so the paging dots
                    // get their own band below it instead of sitting on the
                    // second row's labels.
                    .frame(maxHeight: .infinity, alignment: .top)
                    .tag(pageIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(height: 184)
            Button { showingMenuSheet = false } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 30)
            }
            .padding(.bottom, 6)
        }
        .padding(.top, 14)
        .onAppear { menuPage = 0 }
    }

    private func menuGridCell(_ item: MenuGridItem) -> some View {
        Button {
            if item.keepsSheetOpen {
                item.action()
            } else {
                showingMenuSheet = false
                let action = item.action
                DispatchQueue.main.async { action() }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: item.systemImage)
                    .font(.title2)
                    .frame(height: 30)
                Text(item.label)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(item.isDestructive ? .red : (item.isActive ? .blue : .primary))
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.4)
    }

    /// Pages grouped by function: general (Via's first page), page tools,
    /// navigation & tabs, and per-site controls. Each group fills its own
    /// page; a trailing page with fewer than 4 cells borrows cells from
    /// the previous page so no page looks empty.
    private var menuPages: [[MenuGridItem]] {
        var pages: [[MenuGridItem]] = []
        for group in menuGroups where !group.isEmpty {
            pages.append(contentsOf: stride(from: 0, to: group.count, by: 10).map { Array(group[$0..<min($0 + 10, group.count)]) })
        }
        while pages.count > 1, let lastCount = pages.last?.count, lastCount < 4,
              pages[pages.count - 2].count > 4 {
            let moved = pages[pages.count - 2].removeLast()
            pages[pages.count - 1].insert(moved, at: 0)
        }
        return pages
    }

    private var menuGroups: [[MenuGridItem]] {
        let tab = session.selectedTab
        let isStart = tab?.showsStartPage == true
        let host = (tab?.host ?? "").isEmpty ? nil : tab?.host
        let shareURL = (tab?.urlString).flatMap { URL(string: $0) }.flatMap { $0.scheme != nil ? $0 : nil }

        // 1. Umum — same order as Via's first page.
        let general: [MenuGridItem] = [
            MenuGridItem(label: "Mode Malam", systemImage: isNightMode ? "moon.fill" : "moon", isActive: isNightMode) { toggleNightMode() },
            MenuGridItem(label: "Bookmark", systemImage: "bookmark") { showingBookmarks = true },
            MenuGridItem(label: "Riwayat", systemImage: "clock") { showingHistory = true },
            MenuGridItem(label: "Download", systemImage: "arrow.down.circle") {
                if let exit = onExitToDownloads { exit() } else { dismiss() }
            },
            MenuGridItem(label: "Incognito", systemImage: "eye.slash") { session.newTab(isIncognito: true); capturedNotice = "Tab Incognito baru dibuka." },
            MenuGridItem(label: "Bagikan", systemImage: "square.and.arrow.up", isEnabled: shareURL != nil) {
                if let url = shareURL { shareURLExternally(url) }
            },
            MenuGridItem(label: "Tambah favorit", systemImage: "star", isEnabled: !isStart) { addCurrentToBookmarks() },
            MenuGridItem(label: "Mode Desktop", systemImage: "desktopcomputer", isActive: isDesktopUA) { toggleDesktopUA() },
            MenuGridItem(label: "Alat", systemImage: "briefcase", keepsSheetOpen: true) { menuPage = 1 },
            MenuGridItem(label: "Pengaturan", systemImage: "gearshape") { showingSettingsSheet = true },
        ]

        // 2. Alat halaman: simpan, cari, baca, dan olah halaman ini.
        var tools: [MenuGridItem] = [
            MenuGridItem(label: "Daftar Bacaan", systemImage: "list.bullet") { showingReadingList = true },
            MenuGridItem(label: "Tambah ke Daftar Bacaan", systemImage: "text.badge.plus", isEnabled: !isStart) { addCurrentToReadingList() },
            MenuGridItem(label: "Cari di halaman", systemImage: "magnifyingglass", isEnabled: !isStart) { showingFind = true },
        ]
        if translatedTab == tab?.id {
            tools.append(MenuGridItem(label: "Tampilkan halaman asli", systemImage: "arrow.uturn.backward") { showOriginalPage() })
        } else {
            tools.append(MenuGridItem(label: "Terjemahkan halaman", systemImage: "translate", isEnabled: !isStart) { showingTranslate = true })
        }
        tools.append(MenuGridItem(label: "Mode Baca", systemImage: "book", isEnabled: !isStart) { openReaderMode() })
        if store.browserSettings.showDevToolsButton {
            tools.append(MenuGridItem(label: "DevTools", systemImage: "chevron.left.forwardslash.chevron.right") { showingDevTools = true })
        }
        tools.append(MenuGridItem(label: "Minta AI", systemImage: "sparkles") { openAI() })
        tools.append(MenuGridItem(label: "Cari video & media", systemImage: "play.rectangle.on.rectangle") { session.findMedia() })
        tools.append(MenuGridItem(label: "AdBlock & ekstensi", systemImage: "shield") { showingAdBlock = true })
        tools.append(MenuGridItem(label: "Kata Sandi", systemImage: "key.fill") { showingPasswords = true })
        tools.append(MenuGridItem(label: "Hapus Data…", systemImage: "trash") { showingClearData = true })

        // 3. Navigasi & tab.
        let navigation: [MenuGridItem] = [
            MenuGridItem(label: "Beranda", systemImage: "house") { session.resetTab(session.selectedID) },
            MenuGridItem(label: "Tab Baru", systemImage: "plus") { session.newTab() },
            MenuGridItem(label: "Maju", systemImage: "chevron.right", isEnabled: tab?.canGoForward == true) { session.goForward() },
            MenuGridItem(label: "Riwayat maju", systemImage: "list.bullet", isEnabled: tab?.canGoForward == true) { showingForwardHistory = true },
            MenuGridItem(label: "Fokus ke Alamat", systemImage: "magnifyingglass.circle") { focusAddressBar() },
            MenuGridItem(label: "Muat Ulang", systemImage: "arrow.clockwise", isEnabled: !isStart) { session.reload() },
            MenuGridItem(label: "Muat Ulang Penuh", systemImage: "arrow.clockwise.circle", isEnabled: !isStart) { session.hardReload() },
            MenuGridItem(label: "Tutup tab", systemImage: "xmark", isDestructive: true) {
                if let id = tab?.id { session.closeTab(id) }
            },
        ]

        // 4. Situs ini: per-site toggles, zoom, PiP, dan cetak.
        var site: [MenuGridItem] = []
        if let host {
            let frozen = hostMatches(host, in: store.browserSettings.freezeTimerHosts)
            site.append(MenuGridItem(label: frozen ? "Freeze timer di situs ini ✓" : "Freeze timer di situs ini", systemImage: "timer", isActive: frozen) { toggleFreezeTimer(for: host) })
            let compat = hostMatches(host, in: store.browserSettings.drmCompatHosts)
            site.append(MenuGridItem(label: compat ? "Mode kompatibilitas di situs ini ✓" : "Mode kompatibilitas di situs ini", systemImage: "play.display", isActive: compat) { toggleCompatMode(for: host) })
            if !isStart {
                site.append(MenuGridItem(label: "Perkecil tampilan", systemImage: "minus.magnifyingglass") { adjustZoom(by: -0.1) })
                site.append(MenuGridItem(label: "Perbesar tampilan", systemImage: "plus.magnifyingglass") { adjustZoom(by: 0.1) })
                site.append(MenuGridItem(label: "Reset zoom ke 100%", systemImage: "arrow.counterclockwise", isEnabled: zoomScale(for: host) != 1.0) { resetZoom() })
            }
        }
        if store.browserSettings.pictureInPicture {
            site.append(MenuGridItem(label: "Picture in Picture", systemImage: "pip.enter") { enterPictureInPicture() })
        }
        site.append(MenuGridItem(label: "Cetak Halaman", systemImage: "printer", isEnabled: !isStart) { session.printCurrentPage() })

        return [general, tools, navigation, site]
    }

    private var isNightMode: Bool {
        ["dark", "metro", "breeze", "highContrast"].contains(store.settings.themeName)
    }

    private func toggleNightMode() {
        store.settings.themeName = isNightMode ? "light" : "dark"
        store.save()
    }

    private var isDesktopUA: Bool {
        store.browserSettings.userAgentPreset == UserAgentPreset.mac.rawValue
    }

    private func toggleDesktopUA() {
        store.browserSettings.userAgentPreset = isDesktopUA ? UserAgentPreset.default.rawValue : UserAgentPreset.mac.rawValue
        store.saveBrowserSettings()
        if session.selectedTab?.showsStartPage != true { session.reload() }
    }

    private func focusAddressBar() {
        if let tab = session.selectedTab { addressDraft = tab.urlString }
        isEditingAddress = true
        addressFocused = true
    }

    private func shareURLExternally(_ url: URL) {
        // The menu sheet is still dismissing when this runs; presenting
        // from its view controller fails silently, so wait until it is
        // gone and resolve the top controller then.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard let top = self.mdmTopViewController() else { return }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = activity.popoverPresentationController,
               let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) {
                popover.sourceView = window
                popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
            top.present(activity, animated: true)
        }
    }

    private func mdmTopViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    /// Keyboard shortcuts kept from the old overflow Menu (Cmd+T/R/L/F/D/W/]/P and zoom).
    private var menuKeyboardShortcuts: some View {
        VStack {
            Button { session.newTab() } label: { EmptyView() }.keyboardShortcut("t", modifiers: .command)
            Button { if session.selectedTab?.showsStartPage != true { session.reload() } } label: { EmptyView() }.keyboardShortcut("r", modifiers: .command)
            Button { if session.selectedTab?.showsStartPage != true { session.hardReload() } } label: { EmptyView() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button { focusAddressBar() } label: { EmptyView() }.keyboardShortcut("l", modifiers: .command)
            Button { if session.selectedTab?.showsStartPage != true { showingFind = true } } label: { EmptyView() }.keyboardShortcut("f", modifiers: .command)
            Button { addCurrentToBookmarks() } label: { EmptyView() }.keyboardShortcut("d", modifiers: .command)
            Button { if session.selectedTab?.canGoForward == true { session.goForward() } } label: { EmptyView() }.keyboardShortcut("]", modifiers: .command)
            Button { if let id = session.selectedTab?.id { session.closeTab(id) } } label: { EmptyView() }.keyboardShortcut("w", modifiers: .command)
            if let host = session.selectedTab?.host, !host.isEmpty, session.selectedTab?.showsStartPage != true {
                Button { adjustZoom(by: -0.1) } label: { EmptyView() }.keyboardShortcut("-", modifiers: .command)
                Button { adjustZoom(by: 0.1) } label: { EmptyView() }.keyboardShortcut("=", modifiers: .command)
                Button { resetZoom() } label: { EmptyView() }.keyboardShortcut("0", modifiers: .command)
            }
            Button { if session.selectedTab?.showsStartPage != true { session.printCurrentPage() } } label: { EmptyView() }.keyboardShortcut("p", modifiers: .command)
        }
        .opacity(0)
    }
    @State private var aiContext: (title: String, url: String, text: String)?
    @State private var foundMedia: [URL] = []
    @State private var capturedNotice: String?
    @State private var showingPasswords = false
    @State private var showingAutofillPicker = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        // GeometryReader reads the REAL bottom safe-area inset (which
        // accounts for the tab bar) before anything ignores it, so the
        // navbar can be lifted exactly above the tab bar.
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.clear.ignoresSafeArea()
            ZStack {
                if let tab = session.selectedTab {
                    BrowserWebView(session: session, tabID: tab.id, settings: store.browserSettings)
                        .id(tab.id)
                }
                if session.selectedTab?.showsStartPage == true {
                    StartPageView(session: session, onOpenShield: { showingAdBlock = true })
                }
            }
            // No bottom safe-area inset here on purpose: the page must
            // paint to the physical bottom edge so its content shows
            // through the translucent tab bar. Scroll clearance for the
            // navbar comes from the web view's own scroll insets
            // (see applyScrollInsets), which pad scrolling without
            // shrinking the layout viewport.
            VStack(spacing: 8) {
                if showingFind { findBar }
                // Floating DevTools button (DevSnoop-style): only when
                // the setting is on and a real page is open.
                if store.browserSettings.showDevToolsButton, session.selectedTab?.showsStartPage != true {
                    HStack {
                        Spacer()
                        Button { showingDevTools = true } label: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.body.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                        }
                        .padding(.trailing, 4)
                    }
                }
                if let prompt = session.pendingSavePrompt {
                    saveLoginCard(prompt)
                } else if let offer = session.autofillOffer {
                    autofillCard(offer)
                }
                floatingNavBar
            }
            // Lift the chrome above the tab bar by the real bottom
            // safe-area inset, so the searchbar stays above the tab bar
            // while the page still paints to the physical bottom edge.
            .padding(.bottom, geo.safeAreaInsets.bottom + 6)
        }
        // The whole browser ignores the bottom safe area so the page
        // paints to the physical bottom edge with no white band; the
        // navbar VStack above is lifted clear of the tab bar.
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .top) {
            if let notice = capturedNotice {
                Text(notice)
                    .font(.subheadline).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { capturedNotice = nil } }
            }
        }
        .overlay {
            if showingSiteInfo {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture { showingSiteInfo = false }
                    siteInfoPopup
                }
            }
        }
        .onAppear {
            // Chrome height for scroll clearance: the same bottom inset
            // the navbar is lifted by, plus its lift and height.
            session.bottomScrollInset = geo.safeAreaInsets.bottom + 66
            session.onDownloadCaptured = { url in
                let item = store.addItem(urlString: url.absoluteString)
                capturedNotice = item == nil ? "Link captured, but the URL was rejected." : "Download added: \(item?.fileName ?? url.lastPathComponent)"
            }
            session.onMediaFound = { urls in
                foundMedia = urls
                showingMedia = urls.isEmpty ? false : true
                if urls.isEmpty { capturedNotice = "No playable media found on this page." }
            }
            session.onDevToolsMessage = { [weak session] tabID, body in
                guard let session else { return }
                DevToolsRouter.handle(session: session, tabID: tabID, body: body)
            }
            session.onLoginMessage = { [weak session, weak store] tabID, body in
                guard let session, let store else { return }
                // Only the selected tab may prompt or offer; background
                // tabs stay silent.
                guard tabID == session.selectedID else { return }
                guard let type = body["type"] as? String,
                      let rawHost = body["host"] as? String, !rawHost.isEmpty else { return }
                let host = PasswordStore.normalizeHost(rawHost)
                if type == "detected" {
                    let matches = store.passwords.logins(forHost: host)
                    guard !matches.isEmpty else { return }
                    guard PasswordStore.hostMatches(page: PasswordStore.normalizeHost(session.selectedTab?.host ?? ""), saved: host) else { return }
                    session.autofillOffer = AutofillOffer(host: host, logins: matches)
                    return
                }
                guard type == "submitted",
                      let username = body["username"] as? String,
                      let password = body["password"] as? String, !password.isEmpty else { return }
                let key = "\(host)\n\(username)\n\(password)"
                guard !session.declinedSaveKeys.contains(key) else { return }
                if let existing = store.passwords.logins.first(where: { PasswordStore.normalizeHost($0.host) == host && $0.username == username }),
                   store.passwords.password(for: existing) == password { return }
                if let prompt = session.pendingSavePrompt,
                   prompt.host == host, prompt.username == username, prompt.password == password { return }
                session.pendingSavePrompt = SaveLoginPrompt(host: host, username: username, password: password)
            }
            session.onHistoryRecord = { [weak store] title, url in
                store?.recordHistory(title: title, urlString: url)
            }
            session.onBookmarkAdd = { [weak store] url, title in
                guard let store else { return }
                guard !store.browserSettings.bookmarks.contains(where: { $0.urlString == url }) else {
                    capturedNotice = "Sudah ada di favorit."
                    return
                }
                store.browserSettings.bookmarks.append(BrowserBookmark(title: title.isEmpty ? url : title, urlString: url))
                store.saveBrowserSettings()
                capturedNotice = "Ditambah ke favorit."
            }
            session.onReadingListAdd = { [weak store] url, title in
                guard let store else { return }
                let added = store.addReadingList(title: title.isEmpty ? url : title, urlString: url)
                capturedNotice = added ? "Ditambahkan ke daftar bacaan." : "Sudah ada di daftar bacaan."
            }
            session.applyRulesAndScripts(settings: store.browserSettings)
            session.applyMediaPlaybackSettings(store.browserSettings)
            if let tab = session.selectedTab { addressDraft = tab.urlString }
        }
        .onReceive(store.$browserSettings.dropFirst()) { settings in
            store.saveBrowserSettings()
            if session.skipNextReload {
                session.skipNextReload = false
                session.applyZoomToCurrent()
                return
            }
            session.applyRulesAndScripts(settings: settings)
            session.applyMediaPlaybackSettings(settings)
            session.reload()
        }
        // Save open tabs when the app backgrounds or the browser
        // closes, so a swipe-out-of-recents restart restores them.
        .onChange(of: scenePhase) { phase in
            if phase != .active { session.saveTabs() }
        }
        .onChange(of: session.selectedID) { _ in
            session.pendingSavePrompt = nil
            session.autofillOffer = nil
            showingAutofillPicker = false
        }
        .onChange(of: geo.safeAreaInsets.bottom) { session.bottomScrollInset = $0 + 66 }
        .onDisappear { session.saveTabs() }
        .sheet(isPresented: $showingAdBlock) {
            AdBlockPanelView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingPasswords) {
            NavigationStack {
                PasswordsView(onFill: { login in
                    showingPasswords = false
                    Task {
                        guard await BiometricAuth.authenticate(reason: "Isi login tersimpan untuk \(login.host)") else { return }
                        fillLogin(login)
                    }
                })
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Selesai") { showingPasswords = false } } }
            }
        }
        .sheet(isPresented: $showingAutofillPicker) {
            if let offer = session.autofillOffer {
                NavigationStack {
                    List(offer.logins) { login in
                        Button {
                            showingAutofillPicker = false
                            Task {
                                guard await BiometricAuth.authenticate(reason: "Isi login tersimpan untuk \(offer.host)") else { return }
                                fillLogin(login)
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(login.username.isEmpty ? "(tanpa nama pengguna)" : login.username)
                                Text(offer.host).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .navigationTitle("Pilih login")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Batal") { showingAutofillPicker = false } } }
                }
            }
        }
        .sheet(isPresented: $showingCookies) {
            CookiesView(dataStore: cookieStore, host: currentCleanHost)
        }
        .sheet(isPresented: $showingSiteConfig) {
            SiteConfigView(host: currentCleanHost)
        }
        .sheet(isPresented: $showingMedia) {
            NavigationStack {
                List(foundMedia, id: \.self) { url in
                    Button {
                        _ = store.addItem(urlString: url.absoluteString)
                        showingMedia = false
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .navigationTitle("Media on this page")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingMedia = false } } }
            }
        }
        .fullScreenCover(isPresented: $showingOverview) {
            TabOverviewView(session: session, onAskAI: {
                showingOverview = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openAI() }
            })
        }
        .sheet(isPresented: $showingAI) {
            if let ctx = aiContext {
                AskAIView(pageTitle: ctx.title, pageURL: ctx.url, pageText: ctx.text) { url in
                    session.newTab(url: url)
                }
            }
        }
        .sheet(isPresented: $showingDevTools) {
            DevToolsView(session: session)
                .presentationDetents([.fraction(0.65), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView(session: session)
        }
        .sheet(isPresented: $showingBackHistory) {
            BackForwardHistoryView(session: session, forward: false)
        }
        .sheet(isPresented: $showingForwardHistory) {
            BackForwardHistoryView(session: session, forward: true)
        }
        .sheet(isPresented: $showingBookmarks) {
            BookmarksView(session: session)
        }
        .sheet(isPresented: $showingClearData) {
            ClearDataView()
        }
        .sheet(isPresented: $showingReader) {
            ReaderView(title: readerTitle, articleHTML: readerHTML)
        }
        .sheet(isPresented: $showingTranslate) {
            TranslateView { lang, name in
                showingTranslate = false
                openTranslate(lang: lang, name: name)
            }
        }
        .sheet(isPresented: $showingReadingList) {
            ReadingListView(session: session)
        }
        }
        // The keyboard must not lift the chrome: the bottom lift follows
        // geo.safeAreaInsets.bottom, which grows by the keyboard height,
        // so the searchbar rode to mid-screen and covered the page.
        // Ignore the keyboard safe area — except while the address field
        // or the find bar is being typed in, since those live in the
        // bottom chrome and must stay visible above the keyboard.
        .ignoresSafeArea(isEditingAddress || showingFind ? [] : .keyboard)
    }

    // MARK: Floating transparent navbar (Safari-style: back / address pill / tabs / menu) — no background fill, the page shows through

    private var floatingNavBar: some View {
        HStack(spacing: 10) {
            Button { session.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(session.selectedTab?.canGoBack != true)
            .opacity(session.selectedTab?.canGoBack == true ? 1 : 0.4)
            .onLongPressGesture { showingBackHistory = true }

            addressPill

            Button { showingOverview = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "square.on.square")
                        .font(.body)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                    Text("\(session.tabs.count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.ultraThinMaterial, in: Capsule())
                        .offset(x: 4, y: -4)
                }
            }

            Button { showingMenuSheet = true } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .sheet(isPresented: $showingMenuSheet) {
                menuSheet
                    .presentationDetents([.height(240)])
                    .presentationDragIndicator(.hidden)
            }
            .sheet(isPresented: $showingSettingsSheet) {
                SettingsView(showsDoneButton: true)
            }
            .background(menuKeyboardShortcuts)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// Via-style site popup from the shield button: the site's title and
    /// URL, then the three site actions (cookies, site configuration,
    /// reader mode). Tapping anywhere outside dismisses it.
    private var siteInfoPopup: some View {
        let tab = session.selectedTab
        let title = tab?.title ?? "Situs ini"
        let urlString = tab?.urlString ?? ""
        let shareURL = (tab?.urlString).flatMap { URL(string: $0) }.flatMap { $0.scheme != nil ? $0 : nil }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: store.browserSettings.adBlockEnabled || store.browserSettings.customAdBlockEnabled ? "shield.fill" : "shield")
                    .foregroundStyle(.blue)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button { session.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.primary)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                    siteURLText(urlString)
                        .font(.subheadline)
                        .lineLimit(2)
                }
                Spacer()
                if let shareURL {
                    Button { shareURLExternally(shareURL) } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.primary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Button("Lihat cookie") { showingSiteInfo = false; showingCookies = true }
                if !currentCleanHost.isEmpty {
                    Button("Konfigurasi situs") { showingSiteInfo = false; showingSiteConfig = true }
                }
                Button("Mode Baca") { showingSiteInfo = false; openReaderMode() }
                    .disabled(tab?.showsStartPage == true)
            }
            .font(.subheadline)
            .foregroundStyle(.blue)
        }
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 4)
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    /// The popup's URL line: Via colours the https scheme green.
    private func siteURLText(_ urlString: String) -> Text {
        if urlString.hasPrefix("https://") {
            return Text("https").foregroundColor(.green) + Text(String(urlString.dropFirst(5)))
        }
        return Text(urlString)
    }

    private var currentCleanHost: String {
        BrowserSession.cleanHostEntry(session.selectedTab?.host ?? "")
    }

    private var cookieStore: WKWebsiteDataStore {
        session.webViews[session.selectedID]?.configuration.websiteDataStore ?? WKWebsiteDataStore.default()
    }

    private var addressPill: some View {
        HStack(spacing: 8) {
            Button { showingSiteInfo.toggle() } label: {
                Image(systemName: store.browserSettings.adBlockEnabled || store.browserSettings.customAdBlockEnabled ? "shield.fill" : "shield")
                    .foregroundStyle(.blue)
            }
            TextField("Cari atau masukkan alamat", text: $addressDraft, onEditingChanged: { editing in
                isEditingAddress = editing
                if let tab = session.selectedTab { addressDraft = tab.urlString }
            })
            .focused($addressFocused)
            .autocapitalization(.none).autocorrectionDisabled()
            .onSubmit { commitAddress() }
            .submitLabel(.go)
            if session.selectedTab?.isLoading == true {
                Button { session.stop() } label: { Image(systemName: "xmark") }
            } else {
                Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .onLongPressGesture {
                        // Reynard-style hard reload (long-press reload).
                        if store.browserSettings.gestureHardReload { session.hardReload() }
                    }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .contextMenu {
            if let tab = session.selectedTab, let url = URL(string: tab.urlString), url.scheme != nil {
                Button { UIPasteboard.general.url = url } label: {
                    Label("Salin Link", systemImage: "link")
                }
                ShareLink(item: url) { Label("Bagikan…", systemImage: "square.and.arrow.up") }
                Button { session.newTab(url: url) } label: {
                    Label("Buka di Tab Baru", systemImage: "plus.square.on.square")
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            GeometryReader { geo in
                if let tab = session.selectedTab, tab.isLoading {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * CGFloat(tab.progress)), height: 2.5)
                        .padding(.bottom, 1)
                        .clipShape(Capsule())
                }
            }
        }
        .onChange(of: session.selectedTab?.urlString ?? "") { newValue in
            if !isEditingAddress {
                addressDraft = newValue
            }
        }
    }

    private func commitAddress() {
        guard let url = resolveAddressInput(addressDraft, engine: store.browserSettings.searchEngine) else { return }
        addressFocused = false
        isEditingAddress = false
        session.navigateSelected(to: url)
        addressDraft = url.absoluteString
    }

    /// www-insensitive host-list match (www.contoh.com == contoh.com,
    /// subdomains of a listed host match too).
    private func hostMatches(_ host: String, in entries: [String]) -> Bool {
        func bare(_ s: String) -> String {
            var h = BrowserSession.cleanHostEntry(s)
            if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
            return h
        }
        let h = bare(host)
        return entries.contains { e in
            let b = bare(e)
            return h == b || h.hasSuffix("." + b)
        }
    }

    /// Current zoom scale for a host (100% when the site has no entry).
    private func zoomScale(for host: String) -> Double { session.zoomScale(for: host) }

    /// Steps the site's zoom by `delta` (0.1 steps, 50%...200%) and applies
    /// it live — no page reload, via the skipNextReload flag.
    private func adjustZoom(by delta: Double) {
        guard let host = session.selectedTab?.host, !host.isEmpty else { return }
        let key = BrowserSession.cleanHostEntry(host)
        let stepped = ((zoomScale(for: host) * 10).rounded() + delta * 10) / 10
        let next = min(2.0, max(0.5, stepped))
        session.skipNextReload = true
        if next == 1.0 {
            store.browserSettings.siteZoom.removeValue(forKey: key)
        } else {
            store.browserSettings.siteZoom[key] = next
        }
        store.saveBrowserSettings()
        session.applyZoomToCurrent()
    }

    private func resetZoom() {
        guard let host = session.selectedTab?.host, !host.isEmpty else { return }
        session.skipNextReload = true
        store.browserSettings.siteZoom.removeValue(forKey: BrowserSession.cleanHostEntry(host))
        store.saveBrowserSettings()
        session.applyZoomToCurrent()
    }

    /// Per-site freeze-timer toggle: adds/removes the current host.
    /// Settings changes re-apply rules and reload via onReceive.
    private func toggleFreezeTimer(for host: String) {
        let host = BrowserSession.cleanHostEntry(host)
        var hosts = store.browserSettings.freezeTimerHosts
        if hostMatches(host, in: hosts) {
            hosts.removeAll { hostMatches($0, in: [host]) }
        } else {
            hosts.append(host)
        }
        store.browserSettings.freezeTimerHosts = hosts
        store.saveBrowserSettings()
    }

    /// Compatibility-mode toggle for the current host (DRM video sites):
    /// settings changes re-apply rules and reload via onReceive.
    private func toggleCompatMode(for host: String) {
        let host = BrowserSession.cleanHostEntry(host)
        var hosts = store.browserSettings.drmCompatHosts
        if hostMatches(host, in: hosts) {
            hosts.removeAll { hostMatches($0, in: [host]) }
        } else {
            hosts.append(host)
        }
        store.browserSettings.drmCompatHosts = hosts
        store.saveBrowserSettings()
    }

    private func openReaderMode() {
        session.fetchArticle { title, html in
            DispatchQueue.main.async {
                if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    capturedNotice = "Mode baca tidak menemukan artikel di halaman ini."
                } else {
                    readerTitle = title
                    readerHTML = html
                    showingReader = true
                }
            }
        }
    }

    // MARK: Find in page, translate, reading list

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Cari di halaman…", text: $findQuery)
                .autocapitalization(.none).autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { runFind(backwards: false) }
            if !findQuery.isEmpty {
                Text(findCount == 0 ? "Tidak ada" : "\(findCount) hasil")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button { findStep(backwards: true) } label: { Image(systemName: "chevron.up") }
                .disabled(findQuery.isEmpty)
            Button { findStep(backwards: false) } label: { Image(systemName: "chevron.down") }
                .disabled(findQuery.isEmpty)
            Button("Selesai") { closeFind() }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .task(id: findQuery) {
            guard !findQuery.isEmpty else { findCount = 0; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            runFind(backwards: false)
        }
    }

    private func runFind(backwards: Bool) {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { findCount = 0; return }
        session.countFindMatches(query: q) { n in
            DispatchQueue.main.async { findCount = n }
        }
        session.findInPage(query: q, backwards: backwards)
    }

    private func findStep(backwards: Bool) {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        session.findInPage(query: q, backwards: backwards)
    }

    private func closeFind() {
        showingFind = false
        findQuery = ""
        findCount = 0
        session.clearFindSelection()
    }

    private func openTranslate(lang: String, name: String) {
        session.evaluateJS(BrowserSession.translateScript(lang: lang)) { _, _ in
            DispatchQueue.main.async {
                translatedTab = session.selectedID
                capturedNotice = "Halaman diterjemahkan ke \(name). Muat ulang untuk kembali ke aslinya."
            }
        }
    }

    private func showOriginalPage() {
        translatedTab = nil
        session.reload()
    }

    private func addCurrentToReadingList() {
        guard let tab = session.selectedTab, !tab.urlString.isEmpty,
              let url = URL(string: tab.urlString), url.scheme != nil else { return }
        let added = store.addReadingList(title: tab.displayTitle, urlString: tab.urlString)
        capturedNotice = added ? "Ditambahkan ke daftar bacaan." : "Sudah ada di daftar bacaan."
    }

    private func enterPictureInPicture() {
        session.evaluateJS(BrowserSession.pipScript) { result, _ in
            DispatchQueue.main.async {
                guard let str = result as? String,
                      let data = str.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    capturedNotice = "PiP: tidak ada respons dari halaman."
                    return
                }
                let status = json["status"] as? String ?? "unknown"
                switch status {
                case "none":
                    capturedNotice = "Tidak ada video di halaman ini."
                case "pip":
                    capturedNotice = "Picture in Picture aktif."
                case "pip-playing":
                    capturedNotice = "Memutar video + Picture in Picture…"
                case "unsupported":
                    let hasFn = (json["hasFn"] as? Bool) ?? false
                    var supportsText = "-"
                    if let b = json["supports"] as? Bool { supportsText = b ? "ya" : "tidak" }
                    let paused = (json["paused"] as? Bool) ?? false
                    let videos = json["videos"] as? Int ?? 0
                    let modes = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []).joined(separator: ",")
                    capturedNotice = "PiP gagal (video: \(videos), webkit: \(hasFn ? "ya" : "tidak"), support: \(supportsText), paused: \(paused ? "ya" : "tidak"), mode: \(modes.isEmpty ? "tidak ada" : modes))."
                default:
                    capturedNotice = "PiP: status tidak dikenal."
                }
            }
        }
    }

    private func addCurrentToBookmarks() {
        guard let tab = session.selectedTab,
              let url = URL(string: tab.urlString), url.scheme != nil else {
            capturedNotice = "Buka halaman dulu sebelum menambah favorit."
            return
        }
        guard !store.browserSettings.bookmarks.contains(where: { $0.urlString == tab.urlString }) else {
            capturedNotice = "Sudah ada di favorit."
            return
        }
        store.browserSettings.bookmarks.append(BrowserBookmark(title: tab.displayTitle, urlString: tab.urlString))
        store.saveBrowserSettings()
        capturedNotice = "Ditambah ke favorit."
    }

    // MARK: - Saved logins (password manager cards + autofill)

    /// Card offering to save (or update) the login just submitted.
    private func saveLoginCard(_ prompt: SaveLoginPrompt) -> some View {
        let isUpdate = store.passwords.logins.contains { $0.host == prompt.host && $0.username == prompt.username }
        return VStack(alignment: .leading, spacing: 6) {
            Text(isUpdate ? "Perbarui kata sandi?" : "Simpan kata sandi?")
                .font(.subheadline.weight(.semibold))
            Text("\(prompt.username.isEmpty ? "(tanpa nama pengguna)" : prompt.username) • \(prompt.host)")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Simpan") {
                    store.passwords.save(host: prompt.host, username: prompt.username, password: prompt.password)
                    session.pendingSavePrompt = nil
                    capturedNotice = "Kata sandi tersimpan."
                }
                .buttonStyle(.borderedProminent)
                Button("Jangan") {
                    session.declinedSaveKeys.insert("\(prompt.host)\n\(prompt.username)\n\(prompt.password)")
                    session.pendingSavePrompt = nil
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
    }

    /// Card offering to fill a saved login for this page. Filling always
    /// requires Face ID / the device passcode first.
    private func autofillCard(_ offer: AutofillOffer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Login tersimpan untuk \(offer.host)").font(.subheadline.weight(.semibold))
                Text("Isi otomatis memerlukan Face ID.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Isi") { requestAutofill(offer) }
                .buttonStyle(.borderedProminent)
            Button { session.autofillOffer = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
    }

    private func requestAutofill(_ offer: AutofillOffer) {
        if offer.logins.count == 1 {
            let login = offer.logins[0]
            Task {
                guard await BiometricAuth.authenticate(reason: "Isi login tersimpan untuk \(offer.host)") else { return }
                fillLogin(login)
            }
        } else {
            showingAutofillPicker = true
        }
    }

    private func fillLogin(_ login: SavedLogin) {
        session.autofillOffer = nil
        guard let password = store.passwords.password(for: login),
              let webView = session.webViews[session.selectedID] else { return }
        webView.evaluateJavaScript(PasswordStore.fillScript(username: login.username, password: password)) { result, _ in
            DispatchQueue.main.async {
                capturedNotice = (result as? Bool) == true ? "Login terisi." : "Kolom login tidak ditemukan di halaman ini."
            }
        }
    }

    private func openAI() {
        session.extractPageText { text in
            aiContext = (
                title: session.selectedTab?.displayTitle ?? "",
                url: session.selectedTab?.urlString ?? "",
                text: String(text.prefix(6000))
            )
            showingAI = true
        }
    }
}

// MARK: - Start page (search + favorites + privacy, like Safari/Chrome new tab)

struct StartPageView: View {
    @EnvironmentObject var store: DownloadStore
    @ObservedObject var session: BrowserSession
    var onOpenShield: () -> Void
    @State private var query = ""
    @State private var showingAddBookmark = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                Spacer().frame(height: 8)
                if session.selectedTab?.isIncognito == true {
                    Label("Mode Incognito — riwayat, cookie, dan login tidak disimpan di tab ini.", systemImage: "theatermasks.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.horizontal, 20)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Cari dengan \(store.browserSettings.searchEngine) atau masukkan alamat", text: $query)
                        .focused($searchFocused)
                        .autocapitalization(.none).autocorrectionDisabled()
                        .onSubmit { submitSearch() }
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
                .padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Favorit").font(.headline)
                        Spacer()
                        Text("Lihat Semua").font(.subheadline).foregroundStyle(.secondary).opacity(0)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 16)], spacing: 18) {
                        ForEach(store.browserSettings.bookmarks) { mark in
                            Button {
                                if let url = URL(string: mark.urlString) { session.navigateSelected(to: url) }
                            } label: {
                                VStack(spacing: 6) {
                                    FaviconView(host: URL(string: mark.urlString)?.host ?? "", size: 44)
                                        .padding(10)
                                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                                    Text(mark.title).font(.caption).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.browserSettings.bookmarks.removeAll { $0.id == mark.id }
                                    store.saveBrowserSettings()
                                } label: { Label("Hapus favorit", systemImage: "trash") }
                            }
                        }
                        Button { showingAddBookmark = true } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.title3)
                                    .frame(width: 44, height: 44)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                                Text("Tambah").font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Laporan Privasi", systemImage: "shield.fill").font(.headline)
                    let settings = store.browserSettings
                    let active = (settings.adBlockEnabled ? AdBlockRules.builtinPatterns.count : 0)
                        + (settings.customAdBlockEnabled ? settings.customBlockFilters.count : 0)
                    HStack {
                        Text("AdBlock")
                        Spacer()
                        Text(settings.adBlockEnabled || settings.customAdBlockEnabled ? "Aktif · \(active) aturan" : "Nonaktif")
                            .foregroundStyle(.secondary)
                    }.font(.subheadline)
                    HStack {
                        Text("Ekstensi aktif")
                        Spacer()
                        Text("\(settings.extensions.filter { $0.enabled }.count) dari \(settings.extensions.count)")
                            .foregroundStyle(.secondary)
                    }.font(.subheadline)
                    HStack {
                        Text("Mesin pencari")
                        Spacer()
                        Text(settings.searchEngine).foregroundStyle(.secondary)
                    }.font(.subheadline)
                    Button("Kelola AdBlock & ekstensi…") { onOpenShield() }
                        .font(.subheadline)
                }
                .padding(16)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)

                Text("Tab privat (samaran) tidak menyimpan riwayat, cookie, atau cache. Buka lewat pengalih tab di bawah.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer().frame(height: 20)
            }
            .padding(.top, 12)
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showingAddBookmark) { AddBookmarkView() }
    }

    private func submitSearch() {
        guard let url = resolveAddressInput(query, engine: store.browserSettings.searchEngine) else { return }
        searchFocused = false
        session.navigateSelected(to: url)
    }
}

struct AddBookmarkView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    @State private var title = ""
    @State private var urlString = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nama", text: $title)
                TextField("Alamat (https://…)", text: $urlString)
                    .autocapitalization(.none).autocorrectionDisabled()
            }
            .navigationTitle("Favorit baru")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Batal") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tambah") {
                        let raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty, !raw.isEmpty else { return }
                        let normalized = raw.hasPrefix("http://") || raw.hasPrefix("https://") ? raw : "https://" + raw
                        guard URL(string: normalized) != nil else { return }
                        store.browserSettings.bookmarks.append(BrowserBookmark(title: title, urlString: normalized))
                        store.saveBrowserSettings()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - History, bookmarks, clear browsing data, reader mode

struct BrowserHistoryEntry: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var urlString: String
    var date: Date = Date()
}

struct ReadingListItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var urlString: String
    var date: Date = Date()
    var read: Bool = false
}

/// Back/forward history of the current tab (WKBackForwardList),
/// shown from a long-press on the back button / the ⋯ menu.
/// Tapping an entry jumps straight to it, like Safari's history menu.
struct BackForwardHistoryView: View {
    @ObservedObject var session: BrowserSession
    var forward: Bool
    @Environment(\.dismiss) var dismiss

    private var items: [WKBackForwardListItem] {
        forward ? session.forwardListItems() : session.backListItems().reversed()
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button {
                        session.go(to: item)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title?.isEmpty == false ? (item.title ?? "") : item.url.absoluteString)
                                .lineLimit(1)
                            Text(item.url.absoluteString)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle(forward ? "Riwayat maju" : "Riwayat mundur")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Tutup") { dismiss() } } }
            .overlay {
                if items.isEmpty {
                    Text("Tidak ada riwayat.").foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: DownloadStore
    @ObservedObject var session: BrowserSession
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var showingClearConfirm = false

    private var filtered: [BrowserHistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = store.browserHistory.reversed()
        guard !q.isEmpty else { return Array(all) }
        return all.filter { $0.title.lowercased().contains(q) || $0.urlString.lowercased().contains(q) }
    }

    private var grouped: [(String, [BrowserHistoryEntry])] {
        var dict: [String: [BrowserHistoryEntry]] = [:]
        var order: [String] = []
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "id_ID")
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        for e in filtered {
            let day = cal.startOfDay(for: e.date)
            let label = day == today ? "Hari ini" : (day == yesterday ? "Kemarin" : fmt.string(from: e.date))
            if dict[label] == nil { dict[label] = []; order.append(label) }
            dict[label]?.append(e)
        }
        return order.map { ($0, dict[$0] ?? []) }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                if store.browserHistory.isEmpty {
                    Text("Belum ada riwayat. Halaman yang dibuka di tab biasa tercatat di sini; tab samaran tidak pernah mencatat riwayat.")
                        .foregroundStyle(.secondary)
                } else if filtered.isEmpty {
                    Text("Tidak ada yang cocok dengan pencarian.").foregroundStyle(.secondary)
                } else {
                    ForEach(grouped, id: \.0) { label, entries in
                        Section(label) {
                            ForEach(entries) { entry in
                                Button {
                                    if let url = URL(string: entry.urlString) {
                                        session.navigateSelected(to: url)
                                    }
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title.isEmpty ? (URL(string: entry.urlString)?.host ?? entry.urlString) : entry.title)
                                            .lineLimit(1)
                                        HStack(spacing: 6) {
                                            Text(URL(string: entry.urlString)?.host ?? entry.urlString)
                                            Text(Self.timeFormatter.string(from: entry.date))
                                        }
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { store.removeHistoryEntry(id: entry.id) } label: {
                                        Label("Hapus", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Cari riwayat…")
            .navigationTitle("Riwayat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Tutup") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hapus Semua", role: .destructive) { showingClearConfirm = true }
                        .disabled(store.browserHistory.isEmpty)
                }
            }
            .confirmationDialog("Hapus seluruh riwayat?", isPresented: $showingClearConfirm, titleVisibility: .visible) {
                Button("Hapus Semua", role: .destructive) { store.clearBrowserHistory() }
                Button("Batal", role: .cancel) {}
            }
        }
    }
}

struct BookmarksView: View {
    @EnvironmentObject var store: DownloadStore
    @ObservedObject var session: BrowserSession
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var showingAdd = false
    @State private var editing: BrowserBookmark?
    @State private var showingImporter = false
    @State private var importResult: String?

    private var filtered: [BrowserBookmark] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.browserSettings.bookmarks }
        return store.browserSettings.bookmarks.filter { $0.title.lowercased().contains(q) || $0.urlString.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Tambah bookmark…") { showingAdd = true }
                    Button("Impor dari Safari / Chrome…") { showingImporter = true }
                    Text("iOS tidak mengizinkan aplikasi membaca bookmark Safari atau Chrome langsung. Ekspor dulu dari komputer (Safari: File > Ekspor Bookmark; Chrome: Pengelola Bookmark > Ekspor bookmark), lalu pilih file HTML-nya di sini.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Bookmark (\(filtered.count))") {
                    if filtered.isEmpty {
                        Text("Belum ada bookmark.").foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { mark in
                        Button {
                            if let url = URL(string: mark.urlString) { session.navigateSelected(to: url) }
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mark.title).lineLimit(1)
                                Text(URL(string: mark.urlString)?.host ?? mark.urlString)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.browserSettings.bookmarks.removeAll { $0.id == mark.id }
                                store.saveBrowserSettings()
                            } label: { Label("Hapus", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button { editing = mark } label: { Label("Ubah", systemImage: "pencil") }
                                .tint(.blue)
                        }
                    }
                }
                if let importResult {
                    Section { Text(importResult) }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Cari bookmark…")
            .navigationTitle("Bookmark")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Tutup") { dismiss() } } }
            .sheet(isPresented: $showingAdd) { AddBookmarkView() }
            .sheet(item: $editing) { mark in EditBookmarkView(bookmark: mark) }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [UTType.html], allowsMultipleSelection: false) { result in
                guard let url = try? result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url),
                      let html = String(data: data, encoding: .utf8) else {
                    importResult = "File tidak bisa dibaca."
                    return
                }
                let parsed = Self.parseBookmarkHTML(html)
                let existing = Set(store.browserSettings.bookmarks.map(\.urlString))
                let fresh = parsed.filter { !existing.contains($0.urlString) }
                store.browserSettings.bookmarks.append(contentsOf: fresh)
                store.saveBrowserSettings()
                importResult = fresh.isEmpty
                    ? "Tidak ada bookmark baru — semuanya sudah ada."
                    : "\(fresh.count) bookmark diimpor."
            }
        }
    }

    /// Netscape bookmark HTML: the format Safari and Chrome export.
    static func parseBookmarkHTML(_ html: String) -> [BrowserBookmark] {
        var out: [BrowserBookmark] = []
        let pattern = "<a[^>]+href=\"([^\"]+)\"[^>]*>([^<]*)</a>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return out }
        let range = NSRange(html.startIndex..., in: html)
        for m in regex.matches(in: html, range: range) {
            guard let hrefRange = Range(m.range(at: 1), in: html),
                  let titleRange = Range(m.range(at: 2), in: html) else { continue }
            let href = String(html[hrefRange])
            let title = String(html[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard href.hasPrefix("http://") || href.hasPrefix("https://") else { continue }
            out.append(BrowserBookmark(title: title.isEmpty ? href : title, urlString: href))
        }
        return out
    }
}

struct EditBookmarkView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    var bookmark: BrowserBookmark
    @State private var title = ""
    @State private var urlString = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nama", text: $title)
                TextField("Alamat (https://…)", text: $urlString)
                    .autocapitalization(.none).autocorrectionDisabled()
            }
            .navigationTitle("Ubah bookmark")
            .onAppear {
                title = bookmark.title
                urlString = bookmark.urlString
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Batal") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Simpan") {
                        let raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty, !raw.isEmpty else { return }
                        let normalized = raw.hasPrefix("http://") || raw.hasPrefix("https://") ? raw : "https://" + raw
                        guard URL(string: normalized) != nil else { return }
                        if let idx = store.browserSettings.bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
                            store.browserSettings.bookmarks[idx] = BrowserBookmark(id: bookmark.id, title: title, urlString: normalized)
                            store.saveBrowserSettings()
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ClearDataView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    @State private var clearHistory = true
    @State private var clearCookies = true
    @State private var clearCache = true
    @State private var clearSiteData = false
    @State private var showingConfirm = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Hapus") {
                    Toggle("Riwayat penjelajahan", isOn: $clearHistory)
                    Toggle("Cookie", isOn: $clearCookies)
                    Toggle("Cache", isOn: $clearCache)
                    Toggle("Semua data situs web", isOn: $clearSiteData)
                }
                Section {
                    Text("Cookie dan cache yang dihapus berlaku untuk tab biasa. Tab samaran memakai penyimpanan terpisah yang hilang sendiri saat tab ditutup. Bookmark dan favorit tidak ikut terhapus.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let result {
                    Section { Text(result) }
                }
            }
            .navigationTitle("Hapus Data Penjelajahan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Batal") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hapus") { showingConfirm = true }
                        .disabled(!clearHistory && !clearCookies && !clearCache && !clearSiteData)
                }
            }
            .confirmationDialog("Hapus data yang dipilih?", isPresented: $showingConfirm, titleVisibility: .visible) {
                Button("Hapus", role: .destructive) { performClear() }
                Button("Batal", role: .cancel) {}
            }
        }
    }

    private func performClear() {
        if clearHistory { store.clearBrowserHistory() }
        var types: [String] = []
        if clearCookies { types.append(WKWebsiteDataTypeCookies) }
        if clearCache { types += [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache] }
        if clearSiteData { types = Array(WKWebsiteDataStore.allWebsiteDataTypes()) }
        guard !types.isEmpty else {
            result = "Riwayat dihapus."
            return
        }
        result = "Menghapus…"
        let dataStore = WKWebsiteDataStore.default()
        let typeSet = Set(types)
        dataStore.fetchDataRecords(ofTypes: typeSet) { records in
            dataStore.removeData(ofTypes: typeSet, for: records) {
                DispatchQueue.main.async { result = "Selesai: data yang dipilih sudah dihapus." }
            }
        }
    }
}

struct ReaderWebView: UIViewRepresentable {
    var html: String
    var fontSize: Int

    func makeUIView(context: Context) -> WKWebView {
        WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}

struct ReaderView: View {
    var title: String
    var articleHTML: String
    @State private var fontSize = 18
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ReaderWebView(html: readerHTML, fontSize: fontSize)
                .navigationTitle("Mode Baca")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Tutup") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Stepper("Huruf \(fontSize)", value: $fontSize, in: 14...26, step: 2)
                    }
                }
        }
    }

    private var readerHTML: String {
        let safeTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{font-family:-apple-system,Georgia,serif;font-size:\(fontSize)px;line-height:1.65;color:#1c1c1e;padding:20px 22px 40px;max-width:720px;margin:0 auto;word-wrap:break-word;} h1{font-size:1.4em;line-height:1.3;} img{max-width:100%;height:auto;} a{color:#007aff;} pre,code{white-space:pre-wrap;word-wrap:break-word;} @media (prefers-color-scheme: dark){body{color:#f2f2f7;background:#000;}}</style>
        </head><body><h1>\(safeTitle)</h1>\(articleHTML)</body></html>
        """
    }
}

// MARK: - Translate + reading list

struct TranslateView: View {
    var onTranslate: (String, String) -> Void
    @Environment(\.dismiss) var dismiss

    static let languages: [(code: String, name: String)] = [
        ("id", "Indonesia"), ("en", "English"), ("ms", "Melayu"),
        ("zh-CN", "Mandarin (Sederhana)"), ("zh-TW", "Mandarin (Tradisional)"),
        ("ja", "Jepang"), ("ko", "Korea"), ("ar", "Arab"),
        ("nl", "Belanda"), ("es", "Spanyol"), ("fr", "Prancis"),
        ("de", "Jerman"), ("pt", "Portugis"), ("ru", "Rusia"),
        ("hi", "Hindi"), ("th", "Thailand"), ("vi", "Vietnam"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Self.languages, id: \.code) { lang in
                        Button { onTranslate(lang.code, lang.name) } label: {
                            Text(lang.name)
                        }
                    }
                }
                Section {
                    Text("Halaman diterjemahkan di tempat lewat Google Translate — URL-nya tetap sama. Teks halaman dikirim ke server Google untuk diterjemahkan. Muat ulang halaman untuk kembali ke bahasa aslinya. Sebagian halaman yang sangat interaktif mungkin hanya terterjemah sebagian.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Terjemahkan halaman")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Batal") { dismiss() } } }
        }
    }
}

struct ReadingListView: View {
    @EnvironmentObject var store: DownloadStore
    @ObservedObject var session: BrowserSession
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.readingList.isEmpty {
                    Text("Belum ada yang disimpan. Buka halaman apa pun, lalu ⋯ > Tambah ke Daftar Bacaan untuk membacanya nanti.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.readingList.reversed()) { item in
                        Button {
                            store.setReadingListRead(id: item.id, read: true)
                            if let url = URL(string: item.urlString) { session.navigateSelected(to: url) }
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(item.read ? Color.clear : Color.blue)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title.isEmpty ? (URL(string: item.urlString)?.host ?? item.urlString) : item.title)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(URL(string: item.urlString)?.host ?? item.urlString)
                                        Text(Self.dateString(item.date))
                                    }
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { store.removeReadingList(id: item.id) } label: {
                                Label("Hapus", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { store.setReadingListRead(id: item.id, read: !item.read) } label: {
                                Label(item.read ? "Belum dibaca" : "Sudah dibaca", systemImage: item.read ? "circle" : "checkmark.circle")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Daftar Bacaan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Tutup") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hapus yang sudah dibaca", role: .destructive) { store.clearReadItems() }
                        .disabled(!store.readingList.contains { $0.read })
                }
            }
        }
    }

    static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Tab overview (recent tabs, groups & private tabs — Chrome/Safari style)

enum OverviewDestination: Hashable {
    case group(UUID)
    case inactive
}

struct TabOverviewView: View {
    @EnvironmentObject var store: DownloadStore
    @ObservedObject var session: BrowserSession
    @Environment(\.dismiss) var dismiss
    var onAskAI: () -> Void
    @State private var filterText = ""
    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State private var newGroupColor: Int = BrowserTabGroup.presetColors[0]
    @FocusState private var filterFocused: Bool

    private func matches(_ tab: BrowserTabState) -> Bool {
        guard !filterText.isEmpty else { return true }
        let q = filterText.lowercased()
        return tab.displayTitle.lowercased().contains(q) || tab.host.lowercased().contains(q)
    }

    var filteredNormalTabs: [BrowserTabState] { session.normalTabs.filter(matches) }
    var filteredPrivateTabs: [BrowserTabState] { session.privateTabs.filter(matches) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                segmentedPill
                searchRow
                ScrollView {
                    VStack(spacing: 14) {
                        switch session.overviewMode {
                        case .tabs:
                            if !session.inactiveTabs.isEmpty { inactiveRow }
                            tabGrid(tabs: filteredNormalTabs)
                            if filteredNormalTabs.isEmpty {
                                Text("Tidak ada tab yang cocok.").foregroundStyle(.secondary).padding(.top, 24)
                            }
                        case .privateTabs:
                            if filteredPrivateTabs.isEmpty {
                                privateEmptyState
                            } else {
                                tabGrid(tabs: filteredPrivateTabs)
                            }
                        case .groups:
                            groupsList
                        }
                    }
                    .padding(16)
                }
                bottomBar
            }
            .navigationDestination(for: OverviewDestination.self) { dest in
                switch dest {
                case .group(let id): GroupDetailView(session: session, groupID: id)
                case .inactive: InactiveTabsView(session: session)
                }
            }
            .sheet(isPresented: $showingNewGroup) { newGroupSheet }
        }
        .onAppear { session.captureAllThumbnails() }
    }

    private var segmentedPill: some View {
        HStack(spacing: 0) {
            segmentButton(mode: .privateTabs) {
                Image(systemName: "theatermasks.fill").font(.body)
            }
            segmentButton(mode: .tabs) {
                Text("\(session.normalTabs.count)")
                    .font(.headline)
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.5), lineWidth: 1.5))
            }
            segmentButton(mode: .groups) {
                Image(systemName: "square.grid.2x2").font(.body)
            }
        }
        .padding(4)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .padding(.horizontal, 60)
        .padding(.top, 14)
    }

    private func segmentButton<Content: View>(mode: OverviewMode, @ViewBuilder label: () -> Content) -> some View {
        let selected = session.overviewMode == mode
        return Button { session.overviewMode = mode } label: {
            label()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(selected ? Color(.systemBackground) : Color.clear, in: Capsule())
                .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cari tab…", text: $filterText)
                    .focused($filterFocused)
                    .autocapitalization(.none).autocorrectionDisabled()
                if !filterText.isEmpty {
                    Button { filterText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            Menu {
                Button { showingNewGroup = true } label: { Label("Buat grup baru", systemImage: "folder.badge.plus") }
                Button(role: .destructive) {
                    let ids = session.tabs.map(\.id)
                    for id in ids { session.closeTab(id) }
                    dismiss()
                } label: { Label("Tutup semua tab", systemImage: "xmark") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var inactiveRow: some View {
        NavigationLink(value: OverviewDestination.inactive) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tab tidak aktif").font(.headline)
                    Text("Tab tidak digunakan selama 21 hari").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(session.inactiveTabs.count)").font(.headline)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func tabGrid(tabs: [BrowserTabState]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            ForEach(tabs) { tab in
                TabCardView(session: session, tab: tab) {
                    session.select(tab.id)
                    dismiss()
                }
            }
        }
    }

    private var privateEmptyState: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 40)
            ZStack {
                RoundedRectangle(cornerRadius: 26)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .frame(width: 110, height: 110)
                Image(systemName: "theatermasks.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)
            }
            Text("Tab Samaran Anda akan ditampilkan di sini")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Untuk browsing web secara rahasia, tambahkan tab baru.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 20)
        }
        .padding(.horizontal, 32)
    }

    private var groupsList: some View {
        VStack(spacing: 12) {
            ForEach(session.groups) { group in
                NavigationLink(value: OverviewDestination.group(group.id)) {
                    GroupRowView(session: session, group: group)
                }
                .buttonStyle(.plain)
            }
            if session.groups.isEmpty {
                Text("Belum ada grup. Grup mengumpulkan tab sejenis — misalnya semua tab urusan domain, atau semua tab GitHub — dalam satu wadah berwarna.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 12)
            }
            Button {
                newGroupName = ""
                newGroupColor = BrowserTabGroup.presetColors[0]
                showingNewGroup = true
            } label: {
                Label("Buat grup baru", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private var bottomBar: some View {
        HStack {
            overviewBottomButton(icon: "sparkles", label: "Minta AI") { onAskAI() }
            Spacer()
            overviewBottomButton(icon: "plus.circle", label: "Tab Baru") {
                session.newTab(isIncognito: session.overviewMode == .privateTabs)
                dismiss()
            }
            Spacer()
            overviewBottomButton(icon: "square.grid.2x2", label: "Semua Tab", badge: "\(session.tabs.count)") {
                session.overviewMode = .tabs
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func overviewBottomButton(icon: String, label: String, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon).font(.title3)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                            .offset(x: 10, y: -6)
                    }
                }
                Text(label).font(.caption)
            }
        }
        .buttonStyle(.plain)
    }

    private var newGroupSheet: some View {
        NavigationStack {
            Form {
                TextField("Nama grup", text: $newGroupName)
                Section("Warna") {
                    HStack(spacing: 14) {
                        ForEach(BrowserTabGroup.presetColors, id: \.self) { hex in
                            Button { newGroupColor = hex } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 32, height: 32)
                                    .overlay {
                                        if newGroupColor == hex {
                                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("Grup dibuat kosong — tambah tab dari menu tahan-lama di kartu tab, atau dari halaman grup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Grup baru")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Batal") { showingNewGroup = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Buat") {
                        guard !newGroupName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        _ = session.createGroup(name: newGroupName, colorHex: newGroupColor)
                        showingNewGroup = false
                    }
                }
            }
        }
    }
}

// MARK: - Tab card (snapshot preview + favicon + close)

struct TabCardView: View {
    @ObservedObject var session: BrowserSession
    var tab: BrowserTabState
    var onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = session.thumbnails[tab.id] {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        ZStack {
                            LinearGradient(colors: [Color(.secondarySystemBackground), Color(.systemBackground)], startPoint: .top, endPoint: .bottom)
                            Image(systemName: "globe").font(.largeTitle).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 118)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Button {
                    let wasLast = session.tabs.count <= 1
                    session.closeTab(tab.id)
                    if wasLast { onSelect() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 24, height: 24)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(6)
            }
            HStack(spacing: 6) {
                FaviconView(host: tab.host, size: 18)
                Text(tab.displayTitle).font(.subheadline).lineLimit(1)
                if let g = session.group(of: tab) {
                    Circle().fill(g.color).frame(width: 8, height: 8)
                }
                if tab.isIncognito {
                    Image(systemName: "theatermasks.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(tab.host.isEmpty ? "Tab baru" : tab.host)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            Button { onSelect() } label: { Label("Buka tab", systemImage: "arrow.up.forward.app") }
            if !session.groups.isEmpty {
                Menu("Tambah ke grup") {
                    ForEach(session.groups) { g in
                        Button(g.name) { session.setTabGroup(tab.id, groupID: g.id) }
                    }
                }
            }
            Button("Buat grup baru dari tab ini") {
                _ = session.createGroup(
                    name: tab.displayTitle,
                    colorHex: BrowserTabGroup.presetColors.randomElement() ?? 0x34C759,
                    tabIDs: [tab.id])
            }
            if tab.groupID != nil {
                Button("Keluarkan dari grup") { session.setTabGroup(tab.id, groupID: nil) }
            }
            Divider()
            Button(role: .destructive) {
                let wasLast = session.tabs.count <= 1
                session.closeTab(tab.id)
                if wasLast { onSelect() }
            } label: { Label("Tutup tab", systemImage: "xmark") }
        }
        .onTapGesture { onSelect() }
    }
}

// MARK: - Tab groups: list row & detail

struct GroupRowView: View {
    @ObservedObject var session: BrowserSession
    var group: BrowserTabGroup

    var members: [BrowserTabState] { session.tabs(in: group) }

    var body: some View {
        HStack(spacing: 12) {
            faviconCollage(size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(group.color).frame(width: 10, height: 10)
                    Text(group.name).font(.headline).lineLimit(1)
                }
                Text("Dibuat \(RelativeTime.ago(group.createdAt)) · \(members.count) tab")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    func faviconCollage(size: CGFloat) -> some View {
        let cell = size / 2 - 2
        let shown = Array(members.prefix(4))
        let extra = members.count - shown.count
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                collageCell(tab: shown.indices.contains(0) ? shown[0] : nil, cell: cell)
                if extra > 0 && shown.count == 4 {
                    Text("+\(extra)").font(.caption.weight(.bold))
                        .frame(width: cell, height: cell)
                        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    collageCell(tab: shown.indices.contains(1) ? shown[1] : nil, cell: cell)
                }
            }
            HStack(spacing: 4) {
                collageCell(tab: shown.indices.contains(2) ? shown[2] : nil, cell: cell)
                collageCell(tab: shown.indices.contains(3) ? shown[3] : nil, cell: cell)
            }
        }
        .padding(6)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    func collageCell(tab: BrowserTabState?, cell: CGFloat) -> some View {
        Group {
            if let tab {
                FaviconView(host: tab.host, size: cell * 0.7)
            } else {
                Image(systemName: "globe").foregroundStyle(.secondary).font(.caption)
            }
        }
        .frame(width: cell, height: cell)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct GroupDetailView: View {
    @ObservedObject var session: BrowserSession
    var groupID: UUID
    @Environment(\.dismiss) var dismiss
    @State private var showingRename = false
    @State private var showingAddTabs = false
    @State private var renameName = ""
    @State private var renameColor = 0x34C759

    var group: BrowserTabGroup? { session.groups.first { $0.id == groupID } }

    var body: some View {
        if let group {
            ScrollView {
                VStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(group.color.opacity(0.22))
                            .frame(height: 120)
                        VStack(spacing: 8) {
                            HStack(spacing: 10) {
                                ForEach(session.tabs(in: group).prefix(5)) { tab in
                                    FaviconView(host: tab.host, size: 34)
                                }
                                if session.tabs(in: group).count > 5 {
                                    Text("+\(session.tabs(in: group).count - 5)")
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(group.name).font(.title2.weight(.bold)).lineLimit(1)
                            Text("Dibuat \(RelativeTime.ago(group.createdAt)) · \(session.tabs(in: group).count) tab")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(session.tabs(in: group)) { tab in
                            TabCardView(session: session, tab: tab) {
                                session.select(tab.id)
                                dismiss()
                            }
                        }
                    }
                    if session.tabs(in: group).isEmpty {
                        Text("Grup ini masih kosong. Tambah tab dari tombol di bawah.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button { showingAddTabs = true } label: {
                        Label("Tambah tab ke grup", systemImage: "plus")
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    Button {
                        renameName = group.name
                        renameColor = group.colorHex
                        showingRename = true
                    } label: {
                        Label("Ganti nama & warna", systemImage: "pencil")
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    Button(role: .destructive) {
                        session.deleteGroup(group.id)
                        dismiss()
                    } label: {
                        Label("Hapus grup (tab tetap ada)", systemImage: "trash")
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingRename) {
                NavigationStack {
                    Form {
                        TextField("Nama grup", text: $renameName)
                        Section("Warna") {
                            HStack(spacing: 14) {
                                ForEach(BrowserTabGroup.presetColors, id: \.self) { hex in
                                    Button { renameColor = hex } label: {
                                        Circle().fill(Color(hex: hex)).frame(width: 32, height: 32)
                                            .overlay {
                                                if renameColor == hex {
                                                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .navigationTitle("Ubah grup")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Batal") { showingRename = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Simpan") {
                                session.renameGroup(group.id, name: renameName, colorHex: renameColor)
                                showingRename = false
                            }
                            .disabled(renameName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddTabs) {
                NavigationStack {
                    List {
                        ForEach(session.normalTabs.filter { $0.groupID == nil }) { tab in
                            Button { session.setTabGroup(tab.id, groupID: group.id) } label: {
                                HStack {
                                    FaviconView(host: tab.host, size: 24)
                                    VStack(alignment: .leading) {
                                        Text(tab.displayTitle).lineLimit(1)
                                        Text(tab.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if tab.groupID == group.id {
                                        Image(systemName: "checkmark").foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("Tambah tab")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Selesai") { showingAddTabs = false } } }
                }
            }
        } else {
            Text("Grup tidak ditemukan.").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Inactive tabs (unused for 21+ days)

struct InactiveTabsView: View {
    @ObservedObject var session: BrowserSession
    @Environment(\.dismiss) var dismiss

    var body: some View {
        List {
            Section {
                ForEach(session.inactiveTabs) { tab in
                    Button {
                        session.select(tab.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            FaviconView(host: tab.host, size: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.displayTitle).lineLimit(1)
                                Text("Terakhir dibuka \(RelativeTime.ago(tab.lastUsedAt))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if tab.isIncognito {
                                Image(systemName: "theatermasks.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Tab yang tidak digunakan selama 21 hari dikumpulkan di sini. Buka lagi untuk mengaktifkannya, atau tutup semuanya untuk bersih-bersih.")
            }
            Section {
                Button(role: .destructive) {
                    for tab in session.inactiveTabs { session.closeTab(tab.id) }
                } label: {
                    Text("Tutup semua tab tidak aktif (\(session.inactiveTabs.count))")
                }
            }
        }
        .navigationTitle("Tab tidak aktif")
    }
}

// MARK: - AdBlock panel (built-in + custom together, allowlist wins)

/// UIKit document picker with an explicit delegate. The SwiftUI
/// `.fileImporter` wrapper silently dropped selections when presented
/// from the settings sheet: taps on a file did nothing at all, even
/// with [.item] content types. Presenting the picker directly from
/// the top view controller sidesteps the wrapper entirely.
private final class ScriptPickerPresenter: NSObject, UIDocumentPickerDelegate {
    private var onPick: ((Result<[URL], Error>) -> Void)?

    func present(onPick: @escaping (Result<[URL], Error>) -> Void) {
        self.onPick = onPick
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        Self.topViewController()?.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let pick = onPick
        onPick = nil
        controller.dismiss(animated: true)
        pick?(.success(urls))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onPick = nil
        controller.dismiss(animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// AdBlock & extensions settings, vertical scrolling form grouped by
/// function (like the original panel). Every change saves immediately;
/// anything needing text opens a small editor sheet.
struct AdBlockPanelView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    @State private var editor: PanelEditor?
    @State private var showingExtensions = false
    @State private var showingNewExtension = false
    @State private var editingExtension: BrowserExtension?
    @State private var pickerPresenter = ScriptPickerPresenter()
    @State private var scriptImportResult: String?

    private enum PanelEditor: Identifiable {
        case block, allow, exceptions, freeze, compat, homePage, aiModel
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Perlindungan") {
                    cycleRow(title: "Pelacakan", value: trackingLabel) { cycleTrackingProtection() }
                    Toggle("Hanya HTTPS", isOn: binding(\.httpsOnly))
                    editorRow(title: "Pengecualian", detail: countDetail(store.browserSettings.siteExceptions.count, "situs")) { editor = .exceptions }
                }
                Section("AdBlock") {
                    Toggle("AdBlock Ghostery", isOn: binding(\.adBlockEnabled))
                    Toggle("AdBlock kustom", isOn: binding(\.customAdBlockEnabled))
                    editorRow(title: "Allowlist", detail: countDetail(store.browserSettings.customAllowFilters.count, "entri")) { editor = .allow }
                    editorRow(title: "Filter kustom", detail: countDetail(store.browserSettings.customBlockFilters.count, "filter")) { editor = .block }
                }
                Section("Ekstensi") {
                    Button { showingExtensions = true } label: {
                        HStack { Text("Ekstensi"); Spacer(); Text(extensionsDetail).foregroundStyle(.secondary) }
                    }
                    .buttonStyle(.plain)
                    Button { showingExtensions = true; showingNewExtension = true } label: {
                        HStack { Text("Tambah ekstensi"); Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                    }
                    .buttonStyle(.plain)
                    Button { pickerPresenter.present { importScript(from: $0) } } label: {
                        HStack { Text("Impor file .js"); Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                    }
                    .buttonStyle(.plain)
                }
                Section("AI") {
                    cycleRow(title: "Minta AI", value: store.browserSettings.aiProvider) { cycleAIProvider() }
                    editorRow(title: "Model AI", detail: aiModelLabel) { editor = .aiModel }
                }
                Section("Browser") {
                    cycleRow(title: "Mesin cari", value: store.browserSettings.searchEngine) { cycleSearchEngine() }
                    cycleRow(title: "User Agent", value: uaShortLabel) { cycleUserAgent() }
                    editorRow(title: "Beranda", detail: homeHostLabel) { editor = .homePage }
                }
                Section("Media") {
                    Toggle("Background playback", isOn: binding(\.backgroundPlayback))
                    Toggle("Picture in Picture", isOn: binding(\.pictureInPicture))
                }
                Section("Konten") {
                    Toggle("Blokir popup", isOn: binding(\.blockPopups))
                    Toggle("Pratinjau link", isOn: binding(\.linkPreview))
                    Toggle("Deteksi alamat", isOn: binding(\.detectAddresses))
                    Toggle("Web Inspector", isOn: binding(\.webInspector))
                    Toggle("Lewati timer", isOn: binding(\.skipTimers))
                    Toggle("Tanpa redirect", isOn: binding(\.noRedirects))
                }
                Section("Gestur") {
                    Toggle("Tombol DevTools", isOn: binding(\.showDevToolsButton))
                    Toggle("Geser tepi back/forward", isOn: binding(\.gestureEdgeSwipe))
                    Toggle("Tarik reload", isOn: binding(\.gesturePullRefresh))
                    Toggle("Hard reload", isOn: binding(\.gestureHardReload))
                }
                Section("Situs ini") {
                    editorRow(title: "Freeze timer", detail: countDetail(store.browserSettings.freezeTimerHosts.count, "situs")) { editor = .freeze }
                    editorRow(title: "Mode kompatibilitas", detail: countDetail(store.browserSettings.drmCompatHosts.count, "situs")) { editor = .compat }
                }
            }
            .navigationTitle("AdBlock & Ekstensi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Selesai") { dismiss() } } }
        }
        .sheet(item: $editor) { PanelEditorSheet(editor: $0) }
        .sheet(isPresented: $showingExtensions) { extensionsSheet }
    }

    // MARK: - Rows

    private func cycleRow(title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
        }
        .buttonStyle(.plain)
    }

    private func editorRow(title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let detail { Text(detail).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private var extensionsDetail: String {
        let s = store.browserSettings
        if s.extensions.isEmpty { return "Tidak ada" }
        let active = s.extensions.filter(\.enabled).count
        return "\(s.extensions.count) script, \(active) aktif"
    }

    // MARK: - Helpers

    private func binding(_ keyPath: WritableKeyPath<BrowserSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.browserSettings[keyPath: keyPath] },
            set: { store.browserSettings[keyPath: keyPath] = $0; store.saveBrowserSettings() }
        )
    }

    private func countDetail(_ count: Int, _ noun: String) -> String? {
        count > 0 ? "\(count) \(noun)" : nil
    }

    private var trackingLabel: String {
        switch store.browserSettings.trackingProtection {
        case "off": return "Mati"
        case "strict": return "Ketat"
        default: return "Standar"
        }
    }

    private func cycleTrackingProtection() {
        let order = ["off", "standard", "strict"]
        let current = order.firstIndex(of: store.browserSettings.trackingProtection) ?? 1
        store.browserSettings.trackingProtection = order[(current + 1) % order.count]
        store.saveBrowserSettings()
    }

    private func cycleSearchEngine() {
        let all = SearchEngine.all
        let current = all.firstIndex(of: store.browserSettings.searchEngine) ?? 0
        store.browserSettings.searchEngine = all[(current + 1) % all.count]
        store.saveBrowserSettings()
    }

    private var uaShortLabel: String {
        switch UserAgentPreset(rawValue: store.browserSettings.userAgentPreset) {
        case .iphone: return "Safari iPhone"
        case .ipad: return "Safari iPad"
        case .mac: return "Safari Mac"
        case .chromeWindows: return "Chrome Windows"
        case .chromeAndroid: return "Chrome Android"
        case .firefoxWindows: return "Firefox Windows"
        default: return "Default"
        }
    }

    private func cycleUserAgent() {
        let all = UserAgentPreset.allCases
        let current = all.firstIndex(where: { $0.rawValue == store.browserSettings.userAgentPreset }) ?? 0
        store.browserSettings.userAgentPreset = all[(current + 1) % all.count].rawValue
        store.saveBrowserSettings()
    }

    private func cycleAIProvider() {
        let all = AIProvider.allCases
        let current = all.firstIndex(where: { $0.rawValue == store.browserSettings.aiProvider }) ?? 0
        store.browserSettings.aiProvider = all[(current + 1) % all.count].rawValue
        store.saveBrowserSettings()
    }

    private var aiModelLabel: String {
        let model = store.browserSettings.aiModels[store.browserSettings.aiProvider] ?? ""
        return model.isEmpty ? "Default" : model
    }

    private var homeHostLabel: String {
        URL(string: store.browserSettings.homePage)?.host ?? store.browserSettings.homePage
    }

    // MARK: - Extensions editor (same list as the old panel, in its own sheet)

    private var extensionsSheet: some View {
        NavigationStack {
            Form {
                ForEach($store.browserSettings.extensions) { $ext in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(ext.name, isOn: $ext.enabled)
                        if !ext.matches.isEmpty {
                            Text("Hanya: " + ext.matches.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        HStack(spacing: 8) {
                            Picker("Jalankan", selection: $ext.atDocumentStart) {
                                Text("Akhir dokumen").tag(false)
                                Text("Awal dokumen").tag(true)
                            }
                            .pickerStyle(.segmented)
                            Button("Ubah") { editingExtension = $ext.wrappedValue }
                                .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { store.browserSettings.extensions.remove(atOffsets: $0); store.saveBrowserSettings() }
                Button("Tambah ekstensi…") { showingNewExtension = true }
                Button("Impor file .js…") { pickerPresenter.present { importScript(from: $0) } }
                if let scriptImportResult {
                    Text(scriptImportResult).font(.caption).foregroundStyle(.secondary)
                }
                Text("Userscript jalan di dalam browser ini saja, tidak bisa melihat aplikasi lain.").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Ekstensi")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Selesai") { store.saveBrowserSettings(); dismiss() } } }
            .sheet(isPresented: $showingNewExtension) { NewExtensionView() }
            .sheet(item: $editingExtension) { ext in EditExtensionView(ext: ext) }
        }
    }

    // MARK: - One small editor sheet for every list / text setting

    private struct PanelEditorSheet: View {
        @EnvironmentObject var store: DownloadStore
        @Environment(\.dismiss) var dismiss
        let editor: PanelEditor
        @State private var text = ""

        var body: some View {
            NavigationStack {
                Form {
                    if editor == .homePage || editor == .aiModel {
                        TextField(editor == .homePage ? "Alamat beranda" : "Model", text: $text)
                            .autocapitalization(.none).autocorrectionDisabled()
                    } else {
                        TextEditor(text: $text).frame(minHeight: 120)
                    }
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Batal") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Simpan") { save(); dismiss() } }
                }
                .onAppear { text = initialText }
            }
        }

        private var title: String {
            switch editor {
            case .block: return "Filter kustom"
            case .allow: return "Allowlist"
            case .exceptions: return "Pengecualian situs"
            case .freeze: return "Freeze timer"
            case .compat: return "Mode kompatibilitas"
            case .homePage: return "Beranda"
            case .aiModel: return "Model AI"
            }
        }

        private var hint: String {
            switch editor {
            case .block: return "Satu filter per baris: ||ads.example.com · *.adnxs.com · *banner* · /regex/ — baris ! / # diabaikan."
            case .allow: return "Satu per baris — tidak pernah diblokir, mengalahkan AdBlock."
            case .exceptions: return "Satu host per baris — perlindungan dimatikan untuk situs itu saja."
            case .freeze: return "Satu host per baris — timer halaman dibekukan total di situs itu."
            case .compat: return "Satu host per baris — AdBlock, userscript & UA desktop dimatikan di situs itu."
            case .homePage: return "Alamat halaman beranda."
            case .aiModel: return "Model untuk provider AI yang sedang dipilih. API key disimpan di Keychain, bukan di sini."
            }
        }

        private var initialText: String {
            let s = store.browserSettings
            switch editor {
            case .block: return s.customBlockFilters.joined(separator: "\n")
            case .allow: return s.customAllowFilters.joined(separator: "\n")
            case .exceptions: return s.siteExceptions.joined(separator: "\n")
            case .freeze: return s.freezeTimerHosts.joined(separator: "\n")
            case .compat: return s.drmCompatHosts.joined(separator: "\n")
            case .homePage: return s.homePage
            case .aiModel: return s.aiModels[s.aiProvider] ?? ""
            }
        }

        private func save() {
            let lines = text.components(separatedBy: .newlines)
            switch editor {
            case .block:
                store.browserSettings.customBlockFilters = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case .allow:
                store.browserSettings.customAllowFilters = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case .exceptions:
                store.browserSettings.siteExceptions = lines.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            case .freeze:
                store.browserSettings.freezeTimerHosts = lines.map { BrowserSession.cleanHostEntry($0) }.filter { !$0.isEmpty }
            case .compat:
                store.browserSettings.drmCompatHosts = lines.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            case .homePage:
                store.browserSettings.homePage = text
            case .aiModel:
                store.browserSettings.aiModels[store.browserSettings.aiProvider] = text
            }
            store.saveBrowserSettings()
        }
    }

    private func importScript(from result: Result<[URL], Error>) {
        guard let url = try? result.get().first else { return }
        // startAccessingSecurityScopedResource returns false for URLs
        // that need no security scope (plain on-device files). The old
        // code treated that as "cannot open" and rejected the import.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let source = BrowserExtension.decodeScript(data),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            scriptImportResult = "File kosong atau bukan teks."
            return
        }
        scriptImportResult = store.importUserscript(source: source, fileName: url.lastPathComponent)
    }
}

/// Via-style "Site configuration": a master switch for this host plus
/// the CONTENT overrides (user agent, desktop mode, images, JavaScript).
/// Everything follows the global default until the switch is on and a
/// value is picked; Reset clears the host's overrides.
struct SiteConfigView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    let host: String

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(host)
                        Spacer()
                        Toggle("", isOn: enabledBinding).labelsHidden()
                    }
                }
                Section("CONTENT") {
                    NavigationLink {
                        SiteOptionPicker(title: "User-Agent", options: uaOptions, selection: uaSelection)
                    } label: {
                        HStack { Text("User-Agent"); Spacer(); Text(uaValueLabel).foregroundStyle(.secondary) }
                    }
                    .disabled(!isEnabled)
                    NavigationLink {
                        SiteOptionPicker(title: "Desktop mode", options: [("default", "Default"), ("on", "On"), ("off", "Off")], selection: desktopSelection)
                    } label: {
                        HStack { Text("Desktop mode"); Spacer(); Text(desktopValueLabel).foregroundStyle(.secondary) }
                    }
                    .disabled(!isEnabled)
                    NavigationLink {
                        SiteOptionPicker(title: "Images", options: [("default", "Default"), ("allowed", "Allowed"), ("blocked", "Blocked")], selection: imagesSelection)
                    } label: {
                        HStack { Text("Images"); Spacer(); Text(imagesValueLabel).foregroundStyle(.secondary) }
                    }
                    .disabled(!isEnabled)
                    NavigationLink {
                        SiteOptionPicker(title: "JavaScript", options: [("default", "Default"), ("allowed", "Allowed"), ("blocked", "Blocked")], selection: javaScriptSelection)
                    } label: {
                        HStack { Text("JavaScript"); Spacer(); Text(javaScriptValueLabel).foregroundStyle(.secondary) }
                    }
                    .disabled(!isEnabled)
                }
                Section {
                    Button("Reset", role: .destructive) { reset() }
                        .disabled(!hasOverrides)
                }
            }
            .navigationTitle("Site configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func bare(_ s: String) -> String {
        var h = BrowserSession.cleanHostEntry(s)
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }

    private func matchesBare(_ entry: String, _ host: String) -> Bool {
        let b = bare(entry), h = bare(host)
        return !b.isEmpty && (h == b || h.hasSuffix("." + b))
    }

    private var isEnabled: Bool { store.browserSettings.isSiteConfigEnabled(for: host) }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { isEnabled }, set: { newValue in
            let key = BrowserSession.cleanHostEntry(host)
            var list = store.browserSettings.siteConfigEnabled
            list.removeAll { matchesBare($0, host) }
            if newValue { list.append(key) }
            store.browserSettings.siteConfigEnabled = list
            store.saveBrowserSettings()
        })
    }

    private var hasOverrides: Bool {
        isEnabled
            || store.browserSettings.siteUserAgent.keys.contains { matchesBare($0, host) }
            || store.browserSettings.siteDesktopMode.contains { matchesBare($0, host) }
            || store.browserSettings.siteImagesBlocked.contains { matchesBare($0, host) }
            || store.browserSettings.siteJavaScriptBlocked.contains { matchesBare($0, host) }
    }

    private func reset() {
        store.browserSettings.siteConfigEnabled = store.browserSettings.siteConfigEnabled.filter { !matchesBare($0, host) }
        store.browserSettings.siteUserAgent = store.browserSettings.siteUserAgent.filter { !matchesBare($0.key, host) }
        store.browserSettings.siteDesktopMode = store.browserSettings.siteDesktopMode.filter { !matchesBare($0, host) }
        store.browserSettings.siteImagesBlocked = store.browserSettings.siteImagesBlocked.filter { !matchesBare($0, host) }
        store.browserSettings.siteJavaScriptBlocked = store.browserSettings.siteJavaScriptBlocked.filter { !matchesBare($0, host) }
        store.saveBrowserSettings()
    }

    private func uaShortLabel(_ preset: UserAgentPreset) -> String {
        switch preset {
        case .iphone: return "Safari iPhone"
        case .ipad: return "Safari iPad"
        case .mac: return "Safari Mac"
        case .chromeWindows: return "Chrome Windows"
        case .chromeAndroid: return "Chrome Android"
        case .firefoxWindows: return "Firefox Windows"
        default: return "Default"
        }
    }

    private var globalUALabel: String {
        uaShortLabel(UserAgentPreset(rawValue: store.browserSettings.userAgentPreset) ?? .default)
    }

    private var uaOptions: [(id: String, label: String)] {
        [("default", "Default")] + UserAgentPreset.allCases.map { ($0.rawValue, uaShortLabel($0)) }
    }

    private var uaValueLabel: String {
        if isEnabled {
            for (key, raw) in store.browserSettings.siteUserAgent where matchesBare(key, host) {
                return uaShortLabel(UserAgentPreset(rawValue: raw) ?? .default)
            }
        }
        return "\(globalUALabel) (default)"
    }

    private var uaSelection: Binding<String> {
        Binding(get: {
            for (key, raw) in store.browserSettings.siteUserAgent where matchesBare(key, host) { return raw }
            return "default"
        }, set: { newValue in
            let key = BrowserSession.cleanHostEntry(host)
            store.browserSettings.siteUserAgent = store.browserSettings.siteUserAgent.filter { !matchesBare($0.key, host) }
            if newValue != "default" { store.browserSettings.siteUserAgent[key] = newValue }
            store.saveBrowserSettings()
        })
    }

    private var desktopValueLabel: String {
        store.browserSettings.isSiteDesktopMode(for: host) ? "On" : "Off (default)"
    }

    private var desktopSelection: Binding<String> {
        Binding(get: { store.browserSettings.isSiteDesktopMode(for: host) ? "on" : "default" }, set: { newValue in
            let key = BrowserSession.cleanHostEntry(host)
            var list = store.browserSettings.siteDesktopMode
            list.removeAll { matchesBare($0, host) }
            if newValue == "on" { list.append(key) }
            store.browserSettings.siteDesktopMode = list
            store.saveBrowserSettings()
        })
    }

    private var imagesValueLabel: String {
        store.browserSettings.areSiteImagesBlocked(for: host) ? "Blocked" : "Allowed (default)"
    }

    private var imagesSelection: Binding<String> {
        Binding(get: { store.browserSettings.areSiteImagesBlocked(for: host) ? "blocked" : "default" }, set: { newValue in
            let key = BrowserSession.cleanHostEntry(host)
            var list = store.browserSettings.siteImagesBlocked
            list.removeAll { matchesBare($0, host) }
            if newValue == "blocked" { list.append(key) }
            store.browserSettings.siteImagesBlocked = list
            store.saveBrowserSettings()
        })
    }

    private var javaScriptValueLabel: String {
        store.browserSettings.isSiteJavaScriptBlocked(for: host) ? "Blocked" : "Allowed (default)"
    }

    private var javaScriptSelection: Binding<String> {
        Binding(get: { store.browserSettings.isSiteJavaScriptBlocked(for: host) ? "blocked" : "default" }, set: { newValue in
            let key = BrowserSession.cleanHostEntry(host)
            var list = store.browserSettings.siteJavaScriptBlocked
            list.removeAll { matchesBare($0, host) }
            if newValue == "blocked" { list.append(key) }
            store.browserSettings.siteJavaScriptBlocked = list
            store.saveBrowserSettings()
        })
    }
}

private struct SiteOptionPicker: View {
    let title: String
    let options: [(id: String, label: String)]
    @Binding var selection: String

    var body: some View {
        List {
            ForEach(options, id: \.id) { option in
                Button {
                    selection = option.id
                } label: {
                    HStack {
                        Text(option.label)
                        Spacer()
                        if selection == option.id {
                            Image(systemName: "checkmark").foregroundStyle(.blue)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The current site's cookies (Via's "View cookies"): name, domain, value
/// and expiry, with swipe-to-delete. Only this host's cookies are shown.
struct CookiesView: View {
    @Environment(\.dismiss) var dismiss
    let dataStore: WKWebsiteDataStore
    let host: String
    @State private var cookies: [HTTPCookie] = []

    var body: some View {
        NavigationStack {
            List {
                if cookies.isEmpty {
                    Text("Tidak ada cookie untuk situs ini.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(cookies.enumerated()), id: \.offset) { _, cookie in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cookie.name).font(.headline)
                        Text(cookie.domain).font(.subheadline).foregroundStyle(.secondary)
                        if !cookie.value.isEmpty {
                            Text(cookie.value).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if let expires = cookie.expiresDate {
                            Text("Berlaku sampai \(expires.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Cookie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Selesai") { dismiss() } } }
            .task { load() }
        }
    }

    private func load() {
        dataStore.httpCookieStore.getAllCookies { list in
            let h = BrowserSession.cleanHostEntry(host)
            cookies = list.filter { cookie in
                var d = cookie.domain.lowercased()
                if d.hasPrefix(".") { d = String(d.dropFirst()) }
                return !d.isEmpty && (h == d || h.hasSuffix("." + d))
            }.sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { dataStore.httpCookieStore.delete(cookies[index]) { } }
        cookies.remove(atOffsets: offsets)
    }
}

struct NewExtensionView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var source = ""
    @State private var atDocumentStart = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Extension name", text: $name)
                TextEditor(text: $source).frame(minHeight: 160)
                Picker("Jalankan", selection: $atDocumentStart) {
                    Text("Akhir dokumen").tag(false)
                    Text("Awal dokumen").tag(true)
                }
                .pickerStyle(.segmented)
                Text("Awal dokumen: script jalan sebelum halaman dimuat (misalnya memblokir sesuatu sejak awal). Akhir dokumen: script jalan setelah halaman selesai dimuat.").font(.caption).foregroundStyle(.secondary)
                Text("JavaScript that runs on every page. Keep it short and page-only — no network access beyond the page itself.").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("New extension")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard !name.isEmpty, !source.isEmpty else { return }
                        store.browserSettings.extensions.append(BrowserExtension(name: name, source: source, enabled: true, atDocumentStart: atDocumentStart))
                        store.saveBrowserSettings()
                        dismiss()
                    }
                }
            }
        }
    }
}

struct EditExtensionView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    var extensionID: UUID
    @State private var name: String
    @State private var source: String
    @State private var atDocumentStart: Bool

    init(ext: BrowserExtension) {
        extensionID = ext.id
        _name = State(initialValue: ext.name)
        _source = State(initialValue: ext.source)
        _atDocumentStart = State(initialValue: ext.atDocumentStart)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Extension name", text: $name)
                TextEditor(text: $source).frame(minHeight: 160)
                Picker("Jalankan", selection: $atDocumentStart) {
                    Text("Akhir dokumen").tag(false)
                    Text("Awal dokumen").tag(true)
                }
                .pickerStyle(.segmented)
                Text("Awal dokumen: script jalan sebelum halaman dimuat. Akhir dokumen: script jalan setelah halaman selesai dimuat.").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Ubah extension")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Batal") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Simpan") {
                        guard !name.isEmpty, !source.isEmpty else { return }
                        if let idx = store.browserSettings.extensions.firstIndex(where: { $0.id == extensionID }) {
                            store.browserSettings.extensions[idx].name = name
                            store.browserSettings.extensions[idx].source = source
                            store.browserSettings.extensions[idx].atDocumentStart = atDocumentStart
                            store.saveBrowserSettings()
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}
