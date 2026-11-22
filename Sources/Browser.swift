import SwiftUI
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
    /// Built-in block patterns (domains/substrings). Kept deliberately small:
    /// a curated subset, not a full EasyList (that is ~60k rules and needs
    /// regular list updates, which this app does not fetch).
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

    static func ruleJSON(settings: BrowserSettings) -> String {
        var rules: [[String: Any]] = []
        func blockRule(pattern: String) -> [String: Any] {
            ["trigger": ["url-filter": pattern, "resource-type": ["script", "image", "xmlhttprequest", "media", "font", "websocket"]],
             "action": ["type": "block"]]
        }
        func allowRule(pattern: String) -> [String: Any] {
            ["trigger": ["url-filter": pattern],
             "action": ["type": "ignore-previous-rules"]]
        }
        if settings.adBlockEnabled {
            for p in builtinPatterns {
                rules.append(blockRule(pattern: ".*" + escapeRegex(p) + ".*"))
            }
        }
        if settings.customAdBlockEnabled {
            for line in settings.customBlockFilters {
                if let r = regex(for: line) { rules.append(blockRule(pattern: r)) }
            }
        }
        // Allowlist last: ignore-previous-rules only cancels earlier rules.
        for line in settings.customAllowFilters {
            if let r = regex(for: line) { rules.append(allowRule(pattern: r)) }
        }
        if rules.isEmpty { return "[]" }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func compile(settings: BrowserSettings, completion: @escaping (WKContentRuleList?) -> Void) {
        let json = ruleJSON(settings: settings)
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "mdm-adblock",
            encodedContentRuleList: json
        ) { list, error in
            if error != nil { completion(nil); return }
            completion(list)
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
    var onDownloadCaptured: ((URL) -> Void)?
    var onMediaFound: (([URL]) -> Void)?

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
        AdBlockRules.compile(settings: settings) { [weak self] list in
            guard let self else { return }
            DispatchQueue.main.async {
                self.blockedStatus = list == nil ? "AdBlock: off (no rules)" : "AdBlock: on"
                for (_, webView) in self.webViews {
                    let ucc = webView.configuration.userContentController
                    ucc.removeAllContentRuleLists()
                    if let list { ucc.add(list) }
                    ucc.removeAllUserScripts()
                    for ext in settings.extensions where ext.enabled {
                        ucc.addUserScript(WKUserScript(
                            source: ext.source,
                            injectionTime: ext.atDocumentStart ? .atDocumentStart : .atDocumentEnd,
                            forMainFrameOnly: true))
                    }
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
}

// MARK: - WKWebView wrapper

struct BrowserWebView: UIViewRepresentable {
    @ObservedObject var session: BrowserSession
    var tabID: UUID
    var settings: BrowserSettings

    func makeCoordinator() -> Coordinator { Coordinator(session: session, tabID: tabID) }

    func makeUIView(context: Context) -> WKWebView {
        if let existing = session.webViews[tabID] { return existing }
        let isIncognito = session.tabs.first(where: { $0.id == tabID })?.isIncognito ?? false
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
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
        session.webViews[tabID] = webView
        // Apply rules/scripts once created (compile is async; reload after apply).
        session.applyRulesAndScripts(settings: settings)
        if let pending = session.tabs.first(where: { $0.id == tabID })?.pendingURL {
            webView.load(URLRequest(url: pending))
        }
        context.coordinator.observe(webView: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let tab = session.tabs.first(where: { $0.id == tabID }),
              let pending = tab.pendingURL else { return }
        if webView.url != pending && !(webView.isLoading && webView.url == pending) {
            webView.load(URLRequest(url: pending))
        }
        // Clear pending once loading starts for that URL.
        if webView.url == pending, let idx = session.tabs.firstIndex(where: { $0.id == tabID }) {
            session.tabs[idx].pendingURL = nil
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let session: BrowserSession
        let tabID: UUID
        private var observations: [NSKeyValueObservation] = []
        init(session: BrowserSession, tabID: UUID) { self.session = session; self.tabID = tabID }

        func observe(webView: WKWebView) {
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
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                    guard let self else { return }
                    self.session.updateTab(id: self.tabID, isLoading: wv.isLoading,
                                           canGoBack: wv.canGoBack, canGoForward: wv.canGoForward)
                },
            ]
        }

        // Download capture: attachment responses and non-web files go to the MDM queue.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let downloadExts = ["zip", "rar", "7z", "apk", "ipa", "dmg", "exe", "msi", "pkg", "iso", "torrent", "mp4", "mkv", "mov", "mp3", "flac", "epub"]
            var isDownload = false
            if let http = navigationResponse.response as? HTTPURLResponse,
               let disp = http.allHeaderFields["Content-Disposition"] as? String,
               disp.lowercased().contains("attachment") {
                isDownload = true
            }
            if let url = navigationResponse.response.url {
                let ext = url.pathExtension.lowercased()
                let mime = navigationResponse.response.mimeType ?? ""
                if downloadExts.contains(ext) && !mime.hasPrefix("text/html") { isDownload = true }
            }
            if isDownload, let url = navigationResponse.response.url {
                session.onDownloadCaptured?(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Long-press "Open in new tab" etc. stay in this browser.
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
            return nil
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
            floatingNavBar
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
            session.applyRulesAndScripts(settings: store.browserSettings)
            if let tab = session.selectedTab { addressDraft = tab.host }
        }
        .onReceive(store.$browserSettings.dropFirst()) { settings in
            store.saveBrowserSettings()
            session.applyRulesAndScripts(settings: settings)
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

    var body: some View {
        NavigationStack {
            Form {
                Section("AdBlock") {
                    Toggle("Built-in AdBlock (automatic)", isOn: $store.browserSettings.adBlockEnabled)
                    Toggle("Custom AdBlock (your URL filters)", isOn: $store.browserSettings.customAdBlockEnabled)
                    Text("Both lists run at the same time — built-in and custom rules are merged into one content-rule list. Allowlist entries below override both.").font(.caption).foregroundStyle(.secondary)
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
                    Text("iOS cannot run Chrome extensions — these are page scripts (userscripts) that run inside this browser only, the same approach Safari extensions use. They cannot see other apps or the system. Setiap script bisa dipilih jalannya di awal dokumen (sebelum halaman dimuat) atau akhir dokumen (sesudah halaman dimuat).").font(.caption).foregroundStyle(.secondary)
                }
                Section("Browser") {
                    Picker("Search engine", selection: $store.browserSettings.searchEngine) {
                        ForEach(SearchEngine.all, id: \.self) { engine in
                            Text(engine).tag(engine)
                        }
                    }
                    Toggle("Desktop site", isOn: $store.browserSettings.desktopMode)
                    TextField("Home page", text: $store.browserSettings.homePage)
                        .autocapitalization(.none).autocorrectionDisabled()
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
        }
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
