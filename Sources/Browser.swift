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
    // Timer bypass: speed up countdown waits on download pages.
    var skipTimers: Bool = false
    // No-redirect mode: download clicks go straight to the final link,
    // cross-host popups are dropped.
    var noRedirects: Bool = true
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
        for line in settings.customAllowFilters {
            if let r = regex(for: line) { rules.append(allowRule(pattern: r)) }
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
    // History recording (set by the browser view; skipped for private tabs).
    var onHistoryRecord: ((String, String) -> Void)?
    private var lastHistoryURL: [UUID: String] = [:]
    var onDownloadCaptured: ((URL) -> Void)?
    var onMediaFound: (([URL]) -> Void)?
    // DevTools (F12) state, fed by the in-page bridge script.
    var onDevToolsMessage: ((UUID, [String: Any]) -> Void)?
    @Published var consoleLogs: [UUID: [DevConsoleEntry]] = [:]
    @Published var networkLogs: [UUID: [DevNetworkEntry]] = [:]
    @Published var inspectedElement: DevElementInfo?
    @Published var isInspecting: Bool = false

    init() {
        let firstTab = BrowserTabState()
        tabs = [firstTab]
        selectedID = firstTab.id
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
    }

    func navigateSelected(to url: URL) {
        guard let idx = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        tabs[idx].pendingURL = url
        tabs[idx].urlString = url.absoluteString
        tabs[idx].lastUsedAt = Date()
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
    }

    func goBack() { webViews[selectedID]?.goBack() }
    func goForward() { webViews[selectedID]?.goForward() }
    func reload() { webViews[selectedID]?.reload() }
    func stop() { webViews[selectedID]?.stopLoading() }

    // MARK: Groups

    @discardableResult
    func createGroup(name: String, colorHex: Int, tabIDs: [UUID] = []) -> BrowserTabGroup {
        let group = BrowserTabGroup(name: name, colorHex: colorHex, tabIDs: tabIDs)
        groups.append(group)
        for tabID in tabIDs { setTabGroup(tabID, groupID: group.id) }
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
    }

    func deleteGroup(_ id: UUID) {
        for idx in tabs.indices where tabs[idx].groupID == id { tabs[idx].groupID = nil }
        groups.removeAll { $0.id == id }
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

    func applyRulesAndScripts(settings: BrowserSettings) {
        latestSettings = settings
        AdBlockRules.compile(settings: settings) { [weak self] lists in
            guard let self else { return }
            DispatchQueue.main.async {
                self.blockedStatus = lists.isEmpty ? "AdBlock: off (no rules)" : "AdBlock: on"
                for (_, webView) in self.webViews {
                    let ucc = webView.configuration.userContentController
                    ucc.removeAllContentRuleLists()
                    for list in lists { ucc.add(list) }
                    ucc.removeAllUserScripts()
                    for ext in settings.extensions where ext.enabled {
                        ucc.addUserScript(WKUserScript(
                            source: ext.source,
                            injectionTime: ext.atDocumentStart ? .atDocumentStart : .atDocumentEnd,
                            forMainFrameOnly: true))
                    }
                    // DevTools bridge: always present so console / fetch / XHR
                    // activity can be shown in the F12 panel.
                    ucc.addUserScript(WKUserScript(
                        source: DevToolsBridge.script,
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: true))
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
                    // No-redirect mode: download clicks go straight to the
                    // final link, cross-host popups are dropped.
                    if settings.noRedirects {
                        ucc.addUserScript(WKUserScript(
                            source: BrowserSession.redirectBlockScript,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true))
                    }
                    webView.allowsLinkPreview = settings.linkPreview
                    if #available(iOS 16.4, *) { webView.isInspectable = settings.webInspector }
                    webView.customUserAgent = settings.desktopMode
                        ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
                        : nil
                }
            }
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
        var args = Array.prototype.slice.call(arguments, 2);
        return nativeSetTimeout.apply(window, [fn, scaleDelay(delay)].concat(args));
      };
      window.setInterval = function(fn, delay) {
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
        webView.allowsBackForwardNavigationGestures = true
        // Pull down from the top to reload, Safari-style.
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.didPullToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl
        // DevTools bridge: message handler + document-start script, added
        // before the first load so early console/network activity is seen.
        config.userContentController.add(context.coordinator, name: "mdmDevTools")
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
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            session.clearPending(for: tabID)
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

        // DevTools bridge messages (console / fetch / XHR / inspect picks).
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
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
    if text.contains(" ") || (!text.contains(".") && URL(string: text)?.scheme == nil) {
        return SearchEngine.searchURL(for: engine, query: text)
    }
    if text.hasPrefix("http://") || text.hasPrefix("https://") {
        return URL(string: text)
    }
    return URL(string: "https://" + text)
}

// MARK: - Browser UI (Safari-style floating navbar + Chrome-style overview)

struct BrowserView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    @StateObject private var session = BrowserSession()
    @State private var addressDraft = ""
    @State private var isEditingAddress = false
    @State private var showingAdBlock = false
    @State private var showingMedia = false
    @State private var showingOverview = false
    @State private var showingAI = false
    @State private var showingDevTools = false
    @State private var showingHistory = false
    @State private var showingBookmarks = false
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
    @State private var aiContext: (title: String, url: String, text: String)?
    @State private var foundMedia: [URL] = []
    @State private var capturedNotice: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground).ignoresSafeArea()
            ZStack {
                if let tab = session.selectedTab {
                    BrowserWebView(session: session, tabID: tab.id, settings: store.browserSettings)
                        .id(tab.id)
                }
                if session.selectedTab?.showsStartPage == true {
                    StartPageView(session: session, onOpenShield: { showingAdBlock = true })
                }
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 76) }
            VStack(spacing: 8) {
                if showingFind { findBar }
                floatingNavBar
            }
        }
        .overlay(alignment: .top) {
            if let notice = capturedNotice {
                Text(notice)
                    .font(.subheadline).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { capturedNotice = nil } }
            }
        }
        .onAppear {
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
            session.onHistoryRecord = { [weak store] title, url in
                store?.recordHistory(title: title, urlString: url)
            }
            session.applyRulesAndScripts(settings: store.browserSettings)
            session.applyMediaPlaybackSettings(store.browserSettings)
            if let tab = session.selectedTab { addressDraft = tab.host }
        }
        .onReceive(store.$browserSettings.dropFirst()) { settings in
            store.saveBrowserSettings()
            session.applyRulesAndScripts(settings: settings)
            session.applyMediaPlaybackSettings(settings)
            session.reload()
        }
        .sheet(isPresented: $showingAdBlock) { AdBlockPanelView() }
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
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView(session: session)
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

    // MARK: Floating glass navbar (Safari-style: back / address pill / tabs / menu)

    private var floatingNavBar: some View {
        HStack(spacing: 10) {
            Button { session.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(session.selectedTab?.canGoBack != true)
            .opacity(session.selectedTab?.canGoBack == true ? 1 : 0.4)

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

            Menu {
                Button { dismiss() } label: { Label("Kembali ke Download", systemImage: "xmark.circle") }
                Button { showingDevTools = true } label: { Label("DevTools (F12)", systemImage: "chevron.left.forwardslash.chevron.right") }
                Button { showingHistory = true } label: { Label("Riwayat", systemImage: "clock") }
                Button { showingBookmarks = true } label: { Label("Bookmark", systemImage: "bookmark") }
                Button { openReaderMode() } label: { Label("Mode Baca", systemImage: "book") }
                    .disabled(session.selectedTab?.showsStartPage == true)
                if translatedTab == session.selectedTab?.id {
                    Button { showOriginalPage() } label: { Label("Tampilkan halaman asli", systemImage: "arrow.uturn.backward") }
                } else {
                    Button { showingTranslate = true } label: { Label("Terjemahkan halaman…", systemImage: "translate") }
                        .disabled(session.selectedTab?.showsStartPage == true)
                }
                Button { showingFind = true } label: { Label("Cari di halaman", systemImage: "magnifyingglass") }
                    .disabled(session.selectedTab?.showsStartPage == true)
                Button { addCurrentToReadingList() } label: { Label("Tambah ke Daftar Bacaan", systemImage: "text.badge.plus") }
                    .disabled(session.selectedTab?.showsStartPage == true)
                Button { showingReadingList = true } label: { Label("Daftar Bacaan", systemImage: "list.bullet") }
                Button { showingClearData = true } label: { Label("Hapus Data Penjelajahan…", systemImage: "trash") }
                if store.browserSettings.pictureInPicture {
                    Button { enterPictureInPicture() } label: { Label("Picture in Picture", systemImage: "pip.enter") }
                }
                Divider()
                Button { session.goForward() } label: { Label("Maju", systemImage: "chevron.right") }
                    .disabled(session.selectedTab?.canGoForward != true)
                if let tab = session.selectedTab, let link = URL(string: tab.urlString), link.scheme != nil {
                    ShareLink(item: link) { Label("Bagikan…", systemImage: "square.and.arrow.up") }
                }
                Button { session.findMedia() } label: { Label("Cari video & media", systemImage: "play.rectangle.on.rectangle") }
                Button { addCurrentToBookmarks() } label: { Label("Tambah ke favorit", systemImage: "star") }
                Button { openAI() } label: { Label("Minta AI", systemImage: "sparkles") }
                Button { toggleDesktopMode() } label: {
                    Label(store.browserSettings.desktopMode ? "Mode desktop ✓" : "Mode desktop", systemImage: "desktopcomputer")
                }
                Button { showingAdBlock = true } label: { Label("AdBlock & ekstensi", systemImage: "shield") }
                Divider()
                Button(role: .destructive) {
                    if let id = session.selectedTab?.id { session.closeTab(id) }
                } label: { Label("Tutup tab", systemImage: "xmark") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var addressPill: some View {
        HStack(spacing: 8) {
            Button { showingAdBlock = true } label: {
                Image(systemName: store.browserSettings.adBlockEnabled || store.browserSettings.customAdBlockEnabled ? "shield.fill" : "shield")
                    .foregroundStyle(.blue)
            }
            TextField("Cari atau masukkan alamat", text: $addressDraft, onEditingChanged: { editing in
                isEditingAddress = editing
                if editing, let tab = session.selectedTab { addressDraft = tab.urlString }
                if !editing, let tab = session.selectedTab { addressDraft = tab.host }
            })
            .focused($addressFocused)
            .autocapitalization(.none).autocorrectionDisabled()
            .onSubmit { commitAddress() }
            .submitLabel(.go)
            if session.selectedTab?.isLoading == true {
                Button { session.stop() } label: { Image(systemName: "xmark") }
            } else {
                Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
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
                addressDraft = URL(string: newValue)?.host ?? newValue
            }
        }
    }

    private func commitAddress() {
        guard let url = resolveAddressInput(addressDraft, engine: store.browserSettings.searchEngine) else { return }
        addressFocused = false
        isEditingAddress = false
        session.navigateSelected(to: url)
        addressDraft = url.host ?? url.absoluteString
    }

    private func toggleDesktopMode() {
        store.browserSettings.desktopMode.toggle()
        store.saveBrowserSettings()
        session.applyRulesAndScripts(settings: store.browserSettings)
        session.reload()
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
              let url = URL(string: tab.urlString), url.scheme != nil else { return }
        guard !store.browserSettings.bookmarks.contains(where: { $0.urlString == tab.urlString }) else {
            capturedNotice = "Sudah ada di favorit."
            return
        }
        store.browserSettings.bookmarks.append(BrowserBookmark(title: tab.displayTitle, urlString: tab.urlString))
        store.saveBrowserSettings()
        capturedNotice = "Ditambah ke favorit."
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
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
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

struct AdBlockPanelView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    @State private var blockText = ""
    @State private var allowText = ""
    @State private var showingNewExtension = false
    @State private var editingExtension: BrowserExtension?
    @State private var showingScriptImporter = false
    @State private var scriptImportResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("AdBlock") {
                    Toggle("Ghostery AdBlock (EasyList + EasyPrivacy)", isOn: $store.browserSettings.adBlockEnabled)
                    Toggle("Custom AdBlock (your URL filters)", isOn: $store.browserSettings.customAdBlockEnabled)
                    Text("Filter EasyList + EasyPrivacy — daftar yang dipakai mesin Ghostery — dikonversi ke format content-blocker Apple (snapshot 22 Nov 2026, diperbarui lewat update aplikasi). Daftar Ghostery dan filter kustom jalan bersamaan; allowlist di bawah mengalahkan keduanya.").font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Status", value: "Rules recompile when the browser reloads.")
                }
                Section("Custom block filters (one per line)") {
                    TextEditor(text: Binding(
                        get: { blockText },
                        set: { newValue in
                            blockText = newValue
                            store.browserSettings.customBlockFilters = newValue.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        }))
                        .frame(minHeight: 90)
                        .onAppear { blockText = store.browserSettings.customBlockFilters.joined(separator: "\n") }
                    Text("Examples: ||ads.example.com · *.adnxs.com · *banner* · /regex/ — lines starting with ! or # are ignored.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Allowlist (never blocked)") {
                    TextEditor(text: Binding(
                        get: { allowText },
                        set: { newValue in
                            allowText = newValue
                            store.browserSettings.customAllowFilters = newValue.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        }))
                        .frame(minHeight: 60)
                        .onAppear { allowText = store.browserSettings.customAllowFilters.joined(separator: "\n") }
                }
                Section("Extensions (JavaScript userscripts)") {
                    ForEach($store.browserSettings.extensions) { $ext in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(ext.name, isOn: $ext.enabled)
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
                    .onDelete { store.browserSettings.extensions.remove(atOffsets: $0) }
                    Button("Add extension…") { showingNewExtension = true }
                    Button("Impor file .js…") { showingScriptImporter = true }
                    if let scriptImportResult {
                        Text(scriptImportResult).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("iOS cannot run Chrome extensions — these are page scripts (userscripts) that run inside this browser only, the same approach Safari extensions use. They cannot see other apps or the system. Setiap script bisa dipilih jalannya di awal dokumen (sebelum halaman dimuat) atau akhir dokumen (sesudah halaman dimuat).").font(.caption).foregroundStyle(.secondary)
                }
                Section("Browser") {
                    Picker("Search engine", selection: $store.browserSettings.searchEngine) {
                        ForEach(SearchEngine.all, id: \.self) { engine in
                            Text(engine).tag(engine)
                        }
                    }
                    Toggle("Desktop site", isOn: $store.browserSettings.desktopMode)
                    Toggle("Putar di background (termasuk YouTube)", isOn: $store.browserSettings.backgroundPlayback)
                    Toggle("Picture in Picture", isOn: $store.browserSettings.pictureInPicture)
                    Text("Background dan PiP butuh mode audio di sistem; mematikannya mengembalikan perilaku normal browser (media berhenti saat aplikasi ditutup). YouTube bisa mengubah pemutarnya sewaktu-waktu, jadi fitur ini mungkin perlu penyesuaian lagi.").font(.caption).foregroundStyle(.secondary)
                    TextField("Home page", text: $store.browserSettings.homePage)
                        .autocapitalization(.none).autocorrectionDisabled()
                }
                Section("Konten") {
                    Toggle("Blokir popup", isOn: $store.browserSettings.blockPopups)
                    Toggle("Tampilkan pratinjau link (tekan lama)", isOn: $store.browserSettings.linkPreview)
                    Toggle("Deteksi alamat (buka di Google Maps)", isOn: $store.browserSettings.detectAddresses)
                    Toggle("Web Inspector (periksa dari Safari di Mac)", isOn: $store.browserSettings.webInspector)
                    Toggle("Lewati timer tunggu (countdown download)", isOn: $store.browserSettings.skipTimers)
                    Toggle("Tanpa redirect (klik download langsung ke link final)", isOn: $store.browserSettings.noRedirects)
                    Text("Blokir popup menahan jendela yang dibuka script (window.open); tautan yang diketuk tetap dibuka. Deteksi alamat menandai alamat jalan di halaman menjadi tautan ke Google Maps untuk rute dan info lokal. Web Inspector memungkinkan Safari di Mac memeriksa halaman web ini. Lewati timer mempercepat hitung mundur di halaman download sampai 50x dan mengaktifkan tombol download yang dikunci timer; timer yang ditegakkan server dan verifikasi manusia (mis. Cloudflare) tidak bisa dilewati. Tanpa redirect membuat klik tombol download langsung membuka link finalnya dan membuang popup ke situs lain; popup login/pembayaran yang sah bisa ikut tertahan, matikan kalau perlu.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Minta AI di browser") {
                    Picker("AI", selection: $store.browserSettings.aiProvider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                    TextField("Model", text: Binding(
                        get: { store.browserSettings.aiModels[store.browserSettings.aiProvider] ?? "" },
                        set: { newValue in
                            store.browserSettings.aiModels[store.browserSettings.aiProvider] = newValue
                            store.saveBrowserSettings()
                        }))
                        .autocapitalization(.none).autocorrectionDisabled()
                    Text("API key dimasukkan di panel Minta AI dan disimpan di Keychain perangkat — tidak pernah tersimpan di file pengaturan. Muse tidak punya API publik, jadi pilihannya membuka meta.ai di tab baru.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Browser & AdBlock")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { store.saveBrowserSettings(); dismiss() } } }
            .sheet(isPresented: $showingNewExtension) { NewExtensionView() }
            .sheet(item: $editingExtension) { ext in EditExtensionView(ext: ext) }
            .fileImporter(isPresented: $showingScriptImporter, allowedContentTypes: [UTType.javaScript, UTType.plainText], allowsMultipleSelection: false) { result in
                importScript(from: result)
            }
        }
    }

    private func importScript(from result: Result<[URL], Error>) {
        guard let url = try? result.get().first else { return }
        guard url.startAccessingSecurityScopedResource() else {
            scriptImportResult = "File tidak bisa dibuka."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url),
              let source = String(data: data, encoding: .utf8),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            scriptImportResult = "File kosong atau bukan teks."
            return
        }
        let meta = Self.userscriptMeta(source)
        var base = url.deletingPathExtension().lastPathComponent
        if base.hasSuffix(".user") { base = String(base.dropLast(5)) }
        let name = meta.name ?? (base.isEmpty ? "Userscript" : base)
        store.browserSettings.extensions.append(BrowserExtension(name: name, source: source, enabled: true, atDocumentStart: meta.atStart))
        store.saveBrowserSettings()
        scriptImportResult = "\"\(name)\" diimpor\(meta.atStart ? " (awal dokumen)" : "")."
    }

    /// Userscript metadata block (// ==UserScript== … // ==/UserScript==):
    /// @name becomes the extension name, @run-at document-start picks
    /// "Awal dokumen" timing.
    static func userscriptMeta(_ source: String) -> (name: String?, atStart: Bool) {
        var name: String?
        var atStart = false
        for line in source.components(separatedBy: .newlines).prefix(50) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "// ==/UserScript==" { break }
            guard t.hasPrefix("//") else { continue }
            let body = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("@name") {
                name = body.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if body.hasPrefix("@run-at") {
                atStart = body.dropFirst(7).trimmingCharacters(in: .whitespaces).lowercased().contains("document-start")
            }
        }
        return (name, atStart)
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
