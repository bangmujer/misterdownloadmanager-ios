import SwiftUI
import WebKit

// MARK: - DevTools (Chrome F12 essentials, honest scope)
//
// What this panel does, and what it does not:
// - YES: Console (page console.log/warn/error + window errors, plus a
//   JavaScript REPL that evaluates on the open page), Elements (tap-to-
//   inspect with highlight + tag/id/classes/computed style/HTML, page
//   info, full DOM text), Network (navigation responses, fetch/XHR calls
//   reported live from the page, and the page's own resource-timing
//   buffer), Storage (WebKit cookies, document.cookie, localStorage,
//   sessionStorage, with clearing).
// - NO: a JavaScript debugger with breakpoints, a performance profiler,
//   device emulation beyond the existing desktop-mode toggle, WebSocket
//   frame inspection, or service-worker inspection. WKWebView does not
//   expose those. Console capture is main-frame only, and the resource
//   list only covers what the page's performance buffer kept.

// MARK: - Models

struct DevConsoleEntry: Identifiable {
    var id = UUID()
    var time = Date()
    var level: String
    var text: String
}

struct DevNetworkEntry: Identifiable {
    var id = UUID()
    var time = Date()
    var method: String
    var url: String
    var status: Int
    var durationMs: Int
    var source: String
    var requestHeaders: [String: String] = [:]
    var requestBody: String = ""
    var responseHeaders: [String: String] = [:]
    var responseBody: String = ""
    var mimeType: String = ""
}

struct DevElementInfo {
    var tag: String
    var id: String
    var classes: String
    var text: String
    var html: String
    var rect: String
    var style: [String: String]
}

struct DevResourceEntry: Decodable, Identifiable {
    var id = UUID()
    var name: String
    var type: String
    var duration: Int
    var size: Int
    var start: Int
}

// MARK: - In-page bridge scripts

enum DevToolsBridge {
    /// Installed at document start in every tab. Reports console activity
    /// and fetch/XHR calls back through the "mdmDevTools" message handler.
    static let script = """
    (function() {
      if (window.__mdmDevToolsInstalled) return;
      window.__mdmDevToolsInstalled = true;
      function post(msg) {
        try { window.webkit.messageHandlers.mdmDevTools.postMessage(msg); } catch (e) {}
      }
      function fmt(a) {
        try {
          if (typeof a === 'string') return a;
          if (a instanceof Error) return a.stack || String(a);
          return JSON.stringify(a);
        } catch (e) { try { return String(a); } catch (e2) { return '[object]'; } }
      }
      ['log', 'info', 'warn', 'error', 'debug'].forEach(function(level) {
        var orig = console[level];
        console[level] = function() {
          var args = Array.prototype.slice.call(arguments).map(fmt);
          post({kind: 'console', level: level, text: args.join(' ')});
          return orig.apply(console, arguments);
        };
      });
      window.addEventListener('error', function(e) {
        post({kind: 'console', level: 'error', text: (e.message || 'Script error') + (e.filename ? ' @ ' + e.filename + ':' + e.lineno : '')});
      });
      window.addEventListener('unhandledrejection', function(e) {
        post({kind: 'console', level: 'error', text: 'Unhandled rejection: ' + fmt(e.reason)});
      });
      var origFetch = window.fetch;
      window.fetch = function() {
        var url = '', method = 'GET', reqHeaders = {}, reqBody = '';
        try {
          var input = arguments[0];
          url = (typeof input === 'string') ? input : (input && input.url) || '';
          var opts = arguments[1] || {};
          method = opts.method || (input && input.method) || 'GET';
          if (opts.headers) {
            if (typeof opts.headers.forEach === 'function') { opts.headers.forEach(function(v, k) { reqHeaders[k] = v; }); }
            else if (opts.headers instanceof Array) { opts.headers.forEach(function(p) { reqHeaders[p[0]] = p[1]; }); }
            else { for (var hk in opts.headers) { reqHeaders[hk] = opts.headers[hk]; } }
          }
          if (input && input.headers && typeof input.headers.forEach === 'function') {
            input.headers.forEach(function(v, k) { if (!(k in reqHeaders)) reqHeaders[k] = v; });
          }
          if (opts.body) { reqBody = String(opts.body).slice(0, 4000); }
          else if (input && input.body) { try { reqBody = String(input.body).slice(0, 4000); } catch (e0) {} }
        } catch (e) {}
        var start = performance.now();
        function send(resStatus, resHeaders, resBody, mime) {
          post({kind: 'network', method: method, url: String(url), status: resStatus, duration: Math.round(performance.now() - start), reqHeaders: reqHeaders, reqBody: reqBody, resHeaders: resHeaders || {}, resBody: resBody || '', mime: mime || ''});
        }
        return origFetch.apply(this, arguments).then(function(res) {
          var h = {};
          try { res.headers.forEach(function(v, k) { h[k] = v; }); } catch (e2) {}
          var mime = '';
          try { mime = res.headers.get('content-type') || ''; } catch (e3) {}
          var done = false;
          try {
            var p = res.clone().text();
            if (p && p.then) {
              p.then(function(t) { if (!done) { done = true; send(res.status, h, String(t).slice(0, 20000), mime); } })
               .catch(function() { if (!done) { done = true; send(res.status, h, '', mime); } });
            }
          } catch (e4) {}
          if (!done) { setTimeout(function() { if (!done) { done = true; send(res.status, h, '', mime); } }, 1500); }
          return res;
        }).catch(function(err) {
          send(0, {}, '', '');
          throw err;
        });
      };
      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      var origSetHeader = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function(k, v) {
        try { this.__mdmReqHeaders = this.__mdmReqHeaders || {}; this.__mdmReqHeaders[k] = v; } catch (e) {}
        return origSetHeader.apply(this, arguments);
      };
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__mdmMethod = method; this.__mdmURL = url;
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function(body) {
        var xhr = this, start = performance.now();
        try { xhr.__mdmReqBody = (typeof body === 'string') ? body.slice(0, 4000) : (body ? '[binary]' : ''); } catch (e) {}
        function done() {
          var resHeaders = {};
          try {
            var raw = xhr.getAllResponseHeaders() || '';
            raw.split('\\r\\n').forEach(function(line) {
              var i = line.indexOf(':');
              if (i > 0) resHeaders[line.slice(0, i).trim()] = line.slice(i + 1).trim();
            });
          } catch (e2) {}
          var resBody = '';
          try { resBody = String(xhr.responseText || '').slice(0, 20000); } catch (e3) {}
          var mime = '';
          try { mime = xhr.getResponseHeader('Content-Type') || ''; } catch (e4) {}
          post({kind: 'network', method: xhr.__mdmMethod || 'GET', url: String(xhr.__mdmURL || ''), status: xhr.status || 0, duration: Math.round(performance.now() - start), reqHeaders: xhr.__mdmReqHeaders || {}, reqBody: xhr.__mdmReqBody || '', resHeaders: resHeaders, resBody: resBody, mime: mime});
        }
        xhr.addEventListener('load', done);
        xhr.addEventListener('error', done);
        return origSend.apply(this, arguments);
      };
    })();
    """

    /// Tap-to-inspect: hovering outlines the element, tapping reports it.
    static let startInspect = """
    (function() {
      if (window.__mdmInspectOn) return 'already';
      window.__mdmInspectOn = true;
      var current = null;
      function unoutline(el) {
        if (!el) return;
        try { el.style.outline = el.__mdmPrevOutline || ''; } catch (e) {}
      }
      function outline(el) {
        try {
          if (el.__mdmPrevOutline === undefined) el.__mdmPrevOutline = el.style.outline;
          el.style.outline = '2px solid #ff375f';
        } catch (e) {}
      }
      window.__mdmOver = function(e) {
        if (current && current !== e.target) unoutline(current);
        current = e.target;
        outline(current);
      };
      window.__mdmPick = function(e) {
        e.preventDefault();
        e.stopPropagation();
        var el = e.target;
        var cls = '';
        try { cls = (typeof el.className === 'string') ? el.className : (el.getAttribute('class') || ''); } catch (e2) {}
        var cs = getComputedStyle(el);
        var r = el.getBoundingClientRect();
        var txt = '';
        try { txt = (el.innerText || '').slice(0, 120); } catch (e3) {}
        var html = '';
        try { html = el.outerHTML.slice(0, 2000); } catch (e4) {}
        try {
          window.webkit.messageHandlers.mdmDevTools.postMessage({
            kind: 'inspect',
            tag: String(el.tagName || '').toLowerCase(),
            id: el.id || '',
            classes: cls,
            text: txt,
            html: html,
            rect: 'x ' + Math.round(r.x) + ', y ' + Math.round(r.y) + ', ' + Math.round(r.width) + ' x ' + Math.round(r.height),
            style: { color: cs.color, background: cs.backgroundColor, fontSize: cs.fontSize, display: cs.display, position: cs.position }
          });
        } catch (e5) {}
        window.__mdmStopInspect();
      };
      window.__mdmStopInspect = function() {
        window.__mdmInspectOn = false;
        try {
          document.removeEventListener('mouseover', window.__mdmOver, true);
          document.removeEventListener('click', window.__mdmPick, true);
        } catch (e) {}
        unoutline(current);
        current = null;
      };
      document.addEventListener('mouseover', window.__mdmOver, true);
      document.addEventListener('click', window.__mdmPick, true);
      return 'on';
    })()
    """

    static let stopInspect = """
    (function(){ if (window.__mdmStopInspect) window.__mdmStopInspect(); return 'off'; })()
    """

    static let resourceTiming = """
    (function(){ try { return JSON.stringify(performance.getEntriesByType('resource').map(function(e){ return {name: e.name, type: e.initiatorType || '', duration: Math.round(e.duration || 0), size: Math.round(e.transferSize || 0), start: Math.round(e.startTime || 0)}; }).slice(-200)); } catch(e){ return '[]'; } })()
    """

    static let storageDump = """
    (function(){ var ls = {}, ss = {}; try { for (var i = 0; i < localStorage.length; i++) { var k = localStorage.key(i); ls[k] = String(localStorage.getItem(k)).slice(0, 300); } } catch (e) {} try { for (var j = 0; j < sessionStorage.length; j++) { var k2 = sessionStorage.key(j); ss[k2] = String(sessionStorage.getItem(k2)).slice(0, 300); } } catch (e2) {} return JSON.stringify({cookie: document.cookie || '', local: ls, session: ss}); })()
    """

    static let pageInfo = """
    (function(){ var nav = {}; try { var n = performance.getEntriesByType('navigation')[0]; if (n) nav = {duration: Math.round(n.duration), domContentLoaded: Math.round(n.domContentLoadedEventEnd), load: Math.round(n.loadEventEnd), responseEnd: Math.round(n.responseEnd)}; } catch (e) {} return JSON.stringify({ua: navigator.userAgent, width: window.innerWidth, height: window.innerHeight, dpr: window.devicePixelRatio || 1, charset: document.characterSet || '', title: document.title || '', nav: nav}); })()
    """
}

// MARK: - Message routing (bridge -> session state)

enum DevToolsRouter {
    static func stringDict(_ value: Any?) -> [String: String] {
        guard let d = value as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in d { out[k] = String(describing: v) }
        return out
    }

    static func handle(session: BrowserSession, tabID: UUID, body: [String: Any]) {
        DispatchQueue.main.async {
            guard let kind = body["kind"] as? String else { return }
            switch kind {
            case "console":
                let level = body["level"] as? String ?? "log"
                let text = body["text"] as? String ?? ""
                session.appendConsole(tabID: tabID, level: level, text: text)
            case "network":
                let entry = DevNetworkEntry(
                    method: body["method"] as? String ?? "GET",
                    url: body["url"] as? String ?? "",
                    status: (body["status"] as? NSNumber)?.intValue ?? 0,
                    durationMs: (body["duration"] as? NSNumber)?.intValue ?? 0,
                    source: "fetch/xhr",
                    requestHeaders: DevToolsRouter.stringDict(body["reqHeaders"]),
                    requestBody: body["reqBody"] as? String ?? "",
                    responseHeaders: DevToolsRouter.stringDict(body["resHeaders"]),
                    responseBody: body["resBody"] as? String ?? "",
                    mimeType: body["mime"] as? String ?? "")
                session.appendNetwork(tabID: tabID, entry: entry)
            case "inspect":
                var style: [String: String] = [:]
                if let s = body["style"] as? [String: Any] {
                    for (k, v) in s { style[k] = String(describing: v) }
                }
                session.inspectedElement = DevElementInfo(
                    tag: body["tag"] as? String ?? "",
                    id: body["id"] as? String ?? "",
                    classes: body["classes"] as? String ?? "",
                    text: body["text"] as? String ?? "",
                    html: body["html"] as? String ?? "",
                    rect: body["rect"] as? String ?? "",
                    style: style)
                session.isInspecting = false
            default:
                break
            }
        }
    }
}

// MARK: - Session helpers for DevTools

extension BrowserSession {
    func setInspectMode(_ on: Bool) {
        let script = on ? DevToolsBridge.startInspect : DevToolsBridge.stopInspect
        evaluateJS(script) { [weak self] _, _ in
            DispatchQueue.main.async { self?.isInspecting = on }
        }
    }

    func fetchResourceTiming(completion: @escaping ([DevResourceEntry]) -> Void) {
        evaluateJS(DevToolsBridge.resourceTiming) { result, _ in
            guard let str = result as? String,
                  let data = str.data(using: .utf8),
                  let entries = try? JSONDecoder().decode([DevResourceEntry].self, from: data) else {
                completion([])
                return
            }
            completion(entries)
        }
    }

    func fetchStorageDump(completion: @escaping (String, [String: String], [String: String]) -> Void) {
        evaluateJS(DevToolsBridge.storageDump) { result, _ in
            guard let str = result as? String,
                  let data = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion("", [:], [:])
                return
            }
            let cookie = json["cookie"] as? String ?? ""
            let local = (json["local"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
            let sess = (json["session"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
            completion(cookie, local, sess)
        }
    }

    func fetchPageInfo(completion: @escaping ([String: Any]) -> Void) {
        evaluateJS(DevToolsBridge.pageInfo) { result, _ in
            guard let str = result as? String,
                  let data = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion([:])
                return
            }
            completion(json)
        }
    }

    func fetchCookies(completion: @escaping ([HTTPCookie]) -> Void) {
        guard let webView = webViews[selectedID] else { completion([]); return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies(completion)
    }

    func clearCookies(completion: (() -> Void)? = nil) {
        guard let webView = webViews[selectedID] else { completion?(); return }
        let store = webView.configuration.websiteDataStore
        store.fetchDataRecords(ofTypes: [WKWebsiteDataTypeCookies]) { records in
            store.removeData(ofTypes: [WKWebsiteDataTypeCookies], for: records) {
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    func deleteCookie(_ cookie: HTTPCookie, completion: (() -> Void)? = nil) {
        guard let webView = webViews[selectedID] else { completion?(); return }
        webView.configuration.websiteDataStore.httpCookieStore.delete(cookie) {
            DispatchQueue.main.async { completion?() }
        }
    }

    func clearWebStorage() {
        evaluateJS("try { localStorage.clear(); } catch (e) {} try { sessionStorage.clear(); } catch (e) {}")
    }

    func clearAllSiteData(completion: (() -> Void)? = nil) {
        guard let webView = webViews[selectedID] else { completion?(); return }
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            store.removeData(ofTypes: types, for: records) {
                DispatchQueue.main.async { completion?() }
            }
        }
    }
}

// MARK: - DevTools panel UI

struct DevToolsView: View {
    @ObservedObject var session: BrowserSession
    @Environment(\.dismiss) var dismiss
    @State private var tab = 0
    @State private var jsInput = ""
    @State private var consoleFilter = 0
    @State private var netFilter = ""
    @State private var selectedEntry: DevNetworkEntry?
    @State private var domText = ""
    @State private var domFilter = ""
    @State private var domLoaded = false
    @State private var resources: [DevResourceEntry] = []
    @State private var pageInfo: [String: Any] = [:]
    @State private var infoLoaded = false
    @State private var cookieRaw = ""
    @State private var localItems: [String: String] = [:]
    @State private var sessionItems: [String: String] = [:]
    @State private var webCookies: [HTTPCookie] = []
    @State private var storageLoaded = false

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var tabID: UUID? { session.selectedTab?.id }
    var logs: [DevConsoleEntry] { tabID.flatMap { session.consoleLogs[$0] } ?? [] }
    var netLogs: [DevNetworkEntry] { tabID.flatMap { session.networkLogs[$0] } ?? [] }

    private var filteredLogs: [DevConsoleEntry] {
        switch consoleFilter {
        case 1: return logs.filter { $0.level == "error" }
        case 2: return logs.filter { $0.level == "warn" }
        case 3: return logs.filter { ["log", "info", "debug"].contains($0.level) }
        case 4: return logs.filter { ["input", "result"].contains($0.level) }
        default: return logs
        }
    }

    private var filteredNetLogs: [DevNetworkEntry] {
        let q = netFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return netLogs }
        return netLogs.filter { $0.url.lowercased().contains(q) || $0.method.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // DevSnoop-style header: title + page host + close button.
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.mdmAccent)
                    .frame(width: 34, height: 34)
                    .background(Color.mdmAccent.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("DevTools").font(.headline)
                    Text(session.selectedTab?.host ?? "—").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(Color.mdmSurfaceMuted, in: Circle())
                }
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            // Tab bar with icons + underline, like the reference panel.
            HStack(spacing: 0) {
                devTabButton(index: 0, title: "Console", icon: "terminal")
                devTabButton(index: 1, title: "Elements", icon: "square.stack.3d.up")
                devTabButton(index: 2, title: "Network", icon: "antenna.radiowaves.left.and.right")
                devTabButton(index: 3, title: "Storage", icon: "internaldrive")
            }
            .padding(.horizontal, 8)
            Divider()
            if tab == 0 { consoleTab }
            else if tab == 1 { elementsTab }
            else if tab == 2 { networkTab }
            else { storageTab }
        }
        .preferredColorScheme(.dark)
        .onDisappear { session.setInspectMode(false) }
    }

    private func devTabButton(index: Int, title: String, icon: String) -> some View {
        let selected = tab == index
        return Button { tab = index } label: {
            VStack(spacing: 5) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .blue : .secondary)
                    .padding(.vertical, 6)
                Rectangle()
                    .fill(selected ? Color.blue : Color.clear)
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
    }

    // MARK: Console

    private var consoleTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(filteredLogs.count) dari \(logs.count) entri").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Hapus log") { if let id = tabID { session.consoleLogs[id] = [] } }
                    .font(.subheadline)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Picker("Filter", selection: $consoleFilter) {
                Text("Semua").tag(0)
                Text("Error").tag(1)
                Text("Peringatan").tag(2)
                Text("Info").tag(3)
                Text("Hasil JS").tag(4)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.bottom, 4)
            List {
                if filteredLogs.isEmpty {
                    Text("Belum ada log. Console halaman ini akan muncul di sini — termasuk console.log, peringatan, dan error JavaScript. Muat ulang halaman kalau log awal terlewat.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredLogs) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(Self.timeFormatter.string(from: entry.time))
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                            Image(systemName: icon(for: entry.level))
                                .foregroundStyle(color(for: entry.level))
                                .font(.caption)
                            Text(entry.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .listStyle(.plain)
            HStack(spacing: 8) {
                TextField("Jalankan JavaScript…", text: $jsInput)
                    .autocapitalization(.none).autocorrectionDisabled()
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                    .onSubmit { runJS() }
                Button("Jalankan") { runJS() }
                    .disabled(jsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
    }

    private func runJS() {
        let script = jsInput
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let id = tabID else { return }
        session.appendConsole(tabID: id, level: "input", text: "> " + script)
        jsInput = ""
        session.evaluateJS(script) { result, error in
            DispatchQueue.main.async {
                if let error {
                    session.appendConsole(tabID: id, level: "error", text: String(describing: error))
                } else if let result {
                    session.appendConsole(tabID: id, level: "result", text: Self.stringify(result))
                } else {
                    session.appendConsole(tabID: id, level: "result", text: "undefined")
                }
            }
        }
    }

    static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let s = String(data: data, encoding: .utf8) { return s }
        return String(describing: value)
    }

    func icon(for level: String) -> String {
        switch level {
        case "error": return "xmark.octagon.fill"
        case "warn": return "exclamationmark.triangle.fill"
        case "result": return "arrow.right.circle.fill"
        case "input": return "chevron.right"
        default: return "info.circle"
        }
    }

    func color(for level: String) -> Color {
        switch level {
        case "error": return .red
        case "warn": return .orange
        case "result": return .green
        case "input": return .blue
        default: return .secondary
        }
    }

    // MARK: Elements

    private var elementsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let tab = session.selectedTab {
                    Text(tab.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Button(session.isInspecting ? "Berhenti inspect" : "Inspect elemen (ketuk elemen di halaman)") {
                    session.setInspectMode(!session.isInspecting)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.selectedTab?.showsStartPage == true)
                if let el = session.inspectedElement {
                    elementCard(el)
                }
                HStack(spacing: 8) {
                    Button(infoLoaded ? "Muat ulang info halaman" : "Muat info halaman") { loadPageInfo() }
                    Button(domLoaded ? "Muat ulang DOM" : "Muat DOM") { loadDOM() }
                }
                .buttonStyle(.bordered)
                if infoLoaded { pageInfoCard }
                if domLoaded {
                    TextField("Filter baris DOM…", text: $domFilter)
                        .autocapitalization(.none).autocorrectionDisabled()
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                    Text(displayedDOM)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(14)
        }
    }

    func elementCard(_ el: DevElementInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(el.tag)\(el.id.isEmpty ? "" : "#\(el.id)")\(el.classes.isEmpty ? "" : " ." + el.classes.split(separator: " ").joined(separator: " ."))")
                .font(.headline)
            Text("Posisi: \(el.rect)").font(.caption).foregroundStyle(.secondary)
            if !el.text.isEmpty { Text("Teks: \(el.text)").font(.subheadline) }
            ForEach(el.style.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                HStack { Text(k).font(.caption); Spacer(); Text(v).font(.caption).foregroundStyle(.secondary) }
            }
            Text(el.html)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            Button("Salin HTML") { UIPasteboard.general.string = el.html }
                .font(.subheadline)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var displayedDOM: String {
        let lines = domText.components(separatedBy: .newlines)
        let q = domFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kept = q.isEmpty ? lines : lines.filter { $0.lowercased().contains(q) }
        return Array(kept.prefix(1500)).joined(separator: "\n")
    }

    private func loadDOM() {
        session.evaluateJS("document.documentElement ? document.documentElement.outerHTML : ''") { result, _ in
            DispatchQueue.main.async {
                var html = (result as? String) ?? ""
                if html.count > 200_000 {
                    html = String(html.prefix(200_000)) + "\n…(DOM dipotong, 200 ribu karakter pertama)"
                }
                domText = html
                domLoaded = true
            }
        }
    }

    private func loadPageInfo() {
        session.fetchPageInfo { info in
            DispatchQueue.main.async {
                pageInfo = info
                infoLoaded = true
            }
        }
    }

    private var pageInfoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Info halaman").font(.headline)
            infoRow("Judul", pageInfo["title"] as? String ?? "—")
            if let w = pageInfo["width"] as? NSNumber, let h = pageInfo["height"] as? NSNumber {
                infoRow("Viewport", "\(w.intValue) × \(h.intValue) @\(pageInfo["dpr"] as? NSNumber ?? 1)")
            }
            infoRow("Charset", pageInfo["charset"] as? String ?? "—")
            infoRow("User-Agent", pageInfo["ua"] as? String ?? "—")
            if let nav = pageInfo["nav"] as? [String: Any] {
                infoRow("Muat halaman", "\(nav["duration"] as? NSNumber ?? 0) ms")
                infoRow("DOM siap", "\(nav["domContentLoaded"] as? NSNumber ?? 0) ms")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).font(.caption).lineLimit(4)
        }
    }

    // MARK: Network

    private var networkTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Filter URL atau method", text: $netFilter)
                        .autocapitalization(.none).autocorrectionDisabled()
                        .font(.subheadline)
                    if !netFilter.isEmpty {
                        Button { netFilter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                Button { if let id = tabID { session.networkLogs[id] = [] } } label: {
                    Image(systemName: "trash").frame(width: 36, height: 36)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(12)
            HStack(spacing: 8) {
                Button("Muat resource timing") { loadResources() }
                Spacer()
                Text("\(filteredNetLogs.count) dari \(netLogs.count) entri").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            List {
                Section("Navigasi, fetch & XHR") {
                    if filteredNetLogs.isEmpty {
                        Text(netLogs.isEmpty
                            ? "Belum ada entri. Navigasi dan panggilan fetch/XHR halaman ini tercatat di sini."
                            : "Tidak ada entri yang cocok dengan filter.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filteredNetLogs) { e in
                        Button { selectedEntry = e } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(e.method).font(.caption.weight(.bold))
                                    statusBadge(e.status)
                                    Text(e.source).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(e.durationMs) ms").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(e.url).font(.caption).lineLimit(2).textSelection(.enabled)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !resources.isEmpty {
                    Section("Resource timing (performance)") {
                        ForEach(resources) { r in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(r.type.isEmpty ? "resource" : r.type).font(.caption.weight(.bold))
                                    Spacer()
                                    Text("\(r.duration) ms").font(.caption).foregroundStyle(.secondary)
                                    Text(Self.formatBytes(r.size)).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(r.name).font(.caption).lineLimit(2).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .sheet(item: $selectedEntry) { entry in NetworkDetailView(entry: entry) }
    }

    func statusBadge(_ status: Int) -> some View {
        let color: Color = (200..<300).contains(status) ? .green : (status == 0 ? .secondary : .red)
        return Text("\(status)").font(.caption.weight(.bold)).foregroundStyle(color)
    }

    static func formatBytes(_ n: Int) -> String {
        if n <= 0 { return "—" }
        if n < 1024 { return "\(n) B" }
        return String(format: "%.1f KB", Double(n) / 1024.0)
    }

    private func loadResources() {
        session.fetchResourceTiming { entries in
            DispatchQueue.main.async { resources = entries }
        }
    }

    // MARK: Storage

    private var storageTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button("Muat storage") { loadStorage() }
                    .buttonStyle(.borderedProminent)
                if storageLoaded {
                    Text("Cookie (WebKit)").font(.headline)
                    if webCookies.isEmpty {
                        Text("Tidak ada cookie.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(Array(webCookies.enumerated()), id: \.offset) { _, c in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(c.name) · \(c.domain)").font(.subheadline)
                                Text(String(c.value.prefix(120))).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button { session.deleteCookie(c) { loadStorage() } } label: {
                                Image(systemName: "trash").foregroundStyle(.red)
                            }
                        }
                    }
                    Text("document.cookie").font(.headline)
                    Text(cookieRaw.isEmpty ? "(kosong)" : cookieRaw).font(.caption).textSelection(.enabled)
                    storageDictSection(title: "localStorage", items: localItems) { key in
                        deleteStorageItem(storeName: "localStorage", key: key)
                    }
                    storageDictSection(title: "sessionStorage", items: sessionItems) { key in
                        deleteStorageItem(storeName: "sessionStorage", key: key)
                    }
                    HStack(spacing: 8) {
                        Button("Hapus cookie") { session.clearCookies { loadStorage() } }
                        Button("Hapus local & session") { session.clearWebStorage(); loadStorage() }
                    }
                    .buttonStyle(.bordered)
                    Button("Hapus semua data situs", role: .destructive) { session.clearAllSiteData { loadStorage() } }
                } else {
                    Text("Muat cookie, localStorage, dan sessionStorage halaman ini.").foregroundStyle(.secondary).font(.subheadline)
                }
            }
            .padding(14)
        }
    }

    func storageDictSection(title: String, items: [String: String], onDelete: ((String) -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) (\(items.count))").font(.headline)
            if items.isEmpty {
                Text("(kosong)").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(items.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k).font(.subheadline)
                            Text(v).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                        }
                        Spacer()
                        if let onDelete {
                            Button { onDelete(k) } label: {
                                Image(systemName: "trash").foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        }
    }

    private func deleteStorageItem(storeName: String, key: String) {
        let encoded = "\"" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        session.evaluateJS("try { \(storeName).removeItem(\(encoded)); } catch (e) {}") { _, _ in
            DispatchQueue.main.async { self.loadStorage() }
        }
    }

    private func loadStorage() {
        session.fetchStorageDump { cookie, local, sess in
            DispatchQueue.main.async {
                cookieRaw = cookie
                localItems = local
                sessionItems = sess
                storageLoaded = true
            }
        }
        session.fetchCookies { cookies in
            DispatchQueue.main.async {
                webCookies = cookies
                storageLoaded = true
            }
        }
    }
}

// MARK: - Network request/response detail

struct NetworkDetailView: View {
    var entry: DevNetworkEntry
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Ringkasan") {
                    detailRow("Method", entry.method)
                    detailRow("URL", entry.url)
                    detailRow("Status", "\(entry.status)")
                    detailRow("Waktu", "\(entry.durationMs) ms")
                    detailRow("Sumber", entry.source)
                    if !entry.mimeType.isEmpty { detailRow("Content-Type", entry.mimeType) }
                    detailRow("Waktu catat", Self.timeString(entry.time))
                }
                Section("Request") {
                    if entry.requestHeaders.isEmpty && entry.requestBody.isEmpty {
                        Text("(tidak ada header/body yang tertangkap)").foregroundStyle(.secondary)
                    }
                    ForEach(entry.requestHeaders.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k).font(.caption.weight(.bold))
                            Text(v).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    if !entry.requestBody.isEmpty {
                        Text("Body").font(.caption.weight(.bold))
                        Text(entry.requestBody).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Section("Response") {
                    if entry.responseHeaders.isEmpty {
                        Text("(tidak ada header yang tertangkap)").foregroundStyle(.secondary)
                    }
                    ForEach(entry.responseHeaders.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k).font(.caption.weight(.bold))
                            Text(v).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    if entry.source == "navigation" {
                        Text("Badan respons tidak tersedia untuk navigasi — WebKit tidak mengekspos isi halaman yang dimuat lewat navigasi. Ketuk entri fetch/XHR untuk melihat badan respons.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if entry.responseBody.isEmpty {
                        Text("(badan respons kosong atau tidak tertangkap — mis. respons streaming, biner, atau opaque)").foregroundStyle(.secondary)
                    } else {
                        Text(entry.responseBody).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    Button("Salin badan respons") {
                        UIPasteboard.general.string = entry.responseBody
                    }
                    .disabled(entry.responseBody.isEmpty)
                }
            }
            .navigationTitle("Detail request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Selesai") { dismiss() } } }
        }
    }

    func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }

    static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
