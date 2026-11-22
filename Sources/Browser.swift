import SwiftUI
import WebKit

// MARK: - Browser, ad-block & "extensions" (honest scope)
//
// What iOS allows here, and what it does not:
// - YES: an in-app WKWebView browser with tabs, download capture into the
//   MDM queue, video/media finding, and content-rule ad blocking.
// - YES: built-in + custom URL filters running TOGETHER (both lists are
//   compiled into one WKContentRuleList; allowlist rules win).
// - NO: real Chrome extensions. Chrome's extension APIs do not exist on iOS.
//   The "extensions" here are small JavaScript userscripts the user can
//   toggle, edit and add — same mechanism Safari content blockers use,
//   without pretending to be Chrome extensions.
// - The glass look uses system materials (ultraThinMaterial), which render
//   as Safari-style liquid glass on iOS 26 and as frosted glass on iOS 16/17.

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

struct BrowserSettings: Codable {
    var adBlockEnabled: Bool = true
    var customAdBlockEnabled: Bool = true
    // One filter per line. Forms: "ads.example.com", "||tracker.example", "*.adnxs.com",
    // "*banner*", or a raw regex between /.../. Lines starting with "@@" are allowlist entries.
    var customBlockFilters: [String] = ["||doubleclick.net", "||googlesyndication.com", "*popunder*", "*pop-up*"]
    var customAllowFilters: [String] = []
    var extensions: [BrowserExtension] = BrowserExtension.builtins
    var homePage: String = "https://duckduckgo.com"
    var desktopMode: Bool = false
    var searchEngine: String = "DuckDuckGo"
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

// MARK: - Tabs & session

struct BrowserTabState: Identifiable {
    var id: UUID = UUID()
    var title: String = "New Tab"
    var urlString: String = ""
    var progress: Double = 0
    var isLoading: Bool = false
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var pendingURL: URL?
}

final class BrowserSession: ObservableObject {
    @Published var tabs: [BrowserTabState] = [BrowserTabState()]
    @Published var selectedID: UUID
    @Published var blockedStatus: String = "AdBlock: compiling…"
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

    func select(_ id: UUID) { selectedID = id }
    func newTab(url: URL? = nil, homePage: String) {
        var tab = BrowserTabState()
        if let url { tab.pendingURL = url; tab.urlString = url.absoluteString }
        else if let home = URL(string: homePage) { tab.pendingURL = home; tab.urlString = home.absoluteString }
        tabs.append(tab)
        selectedID = tab.id
    }
    func closeTab(_ id: UUID) {
        guard tabs.count > 1 else { return }
        let idx = tabs.firstIndex { $0.id == id } ?? 0
        tabs.removeAll { $0.id == id }
        webViews[id]?.stopLoading()
        webViews.removeValue(forKey: id)
        if selectedID == id { selectedID = tabs[max(0, idx - 1)].id }
    }
    func navigateSelected(to url: URL) {
        guard let idx = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        tabs[idx].pendingURL = url
        tabs[idx].urlString = url.absoluteString
    }
    func updateTab(id: UUID, title: String? = nil, urlString: String? = nil, progress: Double? = nil,
                   isLoading: Bool? = nil, canGoBack: Bool? = nil, canGoForward: Bool? = nil) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let title, !title.isEmpty { tabs[idx].title = title }
        if let urlString { tabs[idx].urlString = urlString }
        if let progress { tabs[idx].progress = progress }
        if let isLoading { tabs[idx].isLoading = isLoading }
        if let canGoBack { tabs[idx].canGoBack = canGoBack }
        if let canGoForward { tabs[idx].canGoForward = canGoForward }
    }
    func goBack() { webViews[selectedID]?.goBack() }
    func goForward() { webViews[selectedID]?.goForward() }
    func reload() { webViews[selectedID]?.reload() }
    func stop() { webViews[selectedID]?.stopLoading() }

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
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
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

// MARK: - Browser UI (Chrome-like tabs + Safari liquid-glass chrome)

struct BrowserView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    @StateObject private var session = BrowserSession()
    @State private var addressDraft = ""
    @State private var isEditingAddress = false
    @State private var showingAdBlock = false
    @State private var showingMedia = false
    @State private var foundMedia: [URL] = []
    @State private var capturedNotice: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                tabBar
                addressBar
                progressBar
                if let tab = session.selectedTab {
                    BrowserWebView(session: session, tabID: tab.id, settings: store.browserSettings)
                        .id(tab.id)
                }
                Spacer(minLength: 76)
            }
            bottomGlassBar
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
    }

    // MARK: Chrome-style tab strip
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.tabs) { tab in
                    HStack(spacing: 6) {
                        Image(systemName: "globe").font(.caption).foregroundStyle(.secondary)
                        Text(tab.title).lineLimit(1).font(.subheadline)
                            .frame(maxWidth: 140, alignment: .leading)
                        Button { session.closeTab(tab.id) } label: {
                            Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(tab.id == session.selectedID ? Color(.secondarySystemBackground) : Color.clear, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: tab.id == session.selectedID ? 1 : 0))
                    .onTapGesture { session.select(tab.id) }
                }
                Button { session.newTab(homePage: store.browserSettings.homePage) } label: {
                    Image(systemName: "plus").font(.subheadline)
                }
                .padding(7)
                .background(Color(.secondarySystemBackground), in: Circle())
            }
            .padding(.horizontal, 10).padding(.top, 8)
        }
    }

    // MARK: Floating glass address bar (Safari-style)
    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
            TextField("Search or enter address", text: $addressDraft, onEditingChanged: { editing in
                isEditingAddress = editing
                if editing, let tab = session.selectedTab { addressDraft = tab.urlString }
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
            Button { showingAdBlock = true } label: {
                Image(systemName: store.browserSettings.adBlockEnabled || store.browserSettings.customAdBlockEnabled ? "shield.fill" : "shield")
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 12).padding(.top, 8)
        .onAppear { if let tab = session.selectedTab { addressDraft = tab.urlString } }
        .onChange(of: session.selectedTab?.urlString ?? "") { newValue in
            if !isEditingAddress { addressDraft = newValue }
        }
    }

    private var progressBar: some View {
        Group {
            if let tab = session.selectedTab, tab.isLoading {
                ProgressView(value: tab.progress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 16).padding(.top, 4)
            }
        }
    }

    // MARK: Floating glass bottom toolbar
    private var bottomGlassBar: some View {
        HStack(spacing: 4) {
            Button { session.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(session.selectedTab?.canGoBack != true)
            Button { session.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(session.selectedTab?.canGoForward != true)
            Spacer()
            if let url = session.selectedTab?.urlString, let link = URL(string: url), link.scheme != nil {
                ShareLink(item: link) { Image(systemName: "square.and.arrow.up") }
            }
            Button { session.findMedia() } label: { Image(systemName: "play.rectangle.on.rectangle") }
            Button { session.newTab(homePage: store.browserSettings.homePage) } label: { Image(systemName: "plus.square.on.square") }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
        }
        .font(.title3)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func commitAddress() {
        let raw = addressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        addressFocused = false
        isEditingAddress = false
        let url: URL?
        if raw.contains(" ") || (!raw.contains(".") && URL(string: raw)?.scheme == nil) {
            let engine = store.browserSettings.searchEngine
            let base = engine == "Google" ? "https://www.google.com/search?q=" : "https://duckduckgo.com/?q="
            url = URL(string: base + (raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw))
        } else if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            url = URL(string: raw)
        } else {
            url = URL(string: "https://" + raw)
        }
        if let url { session.navigateSelected(to: url) }
    }
}

// MARK: - AdBlock panel (built-in + custom together, allowlist wins)

struct AdBlockPanelView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    @State private var blockText = ""
    @State private var allowText = ""
    @State private var showingNewExtension = false

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
                        Toggle(ext.name, isOn: $ext.enabled)
                    }
                    .onDelete { store.browserSettings.extensions.remove(atOffsets: $0) }
                    Button("Add extension…") { showingNewExtension = true }
                    Text("iOS cannot run Chrome extensions — these are page scripts (userscripts) that run inside this browser only, the same approach Safari extensions use. They cannot see other apps or the system.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Browser") {
                    Picker("Search engine", selection: $store.browserSettings.searchEngine) {
                        Text("DuckDuckGo").tag("DuckDuckGo"); Text("Google").tag("Google")
                    }
                    Toggle("Desktop site", isOn: $store.browserSettings.desktopMode)
                    TextField("Home page", text: $store.browserSettings.homePage)
                        .autocapitalization(.none).autocorrectionDisabled()
                }
            }
            .navigationTitle("Browser & AdBlock")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { store.saveBrowserSettings(); dismiss() } } }
            .sheet(isPresented: $showingNewExtension) { NewExtensionView() }
        }
    }
}

struct NewExtensionView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var source = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Extension name", text: $name)
                TextEditor(text: $source).frame(minHeight: 160)
                Text("JavaScript that runs on every page after it loads. Keep it short and page-only — no network access beyond the page itself.").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("New extension")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard !name.isEmpty, !source.isEmpty else { return }
                        store.browserSettings.extensions.append(BrowserExtension(name: name, source: source, enabled: true))
                        store.saveBrowserSettings()
                        dismiss()
                    }
                }
            }
        }
    }
}
