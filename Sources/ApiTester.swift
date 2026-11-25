import SwiftUI
import Foundation

// MARK: - API Tester models

/// An HTTP request the user can compose, send, and re-run, in the
/// style of the standalone API-tester apps: method, URL, query
/// params, headers, auth, and a raw body, with the last response
/// kept alongside it so the AI tab can read it too.
enum ApiMethod: String, CaseIterable, Codable {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE", head = "HEAD", options = "OPTIONS"

    var allowsBody: Bool { [.post, .put, .patch].contains(self) }

    var tint: Color {
        switch self {
        case .get: return .blue
        case .post: return .green
        case .put: return .orange
        case .patch: return .purple
        case .delete: return .red
        case .head, .options: return .gray
        }
    }
}

struct ApiKeyValue: Identifiable, Codable, Equatable {
    var id = UUID()
    var enabled = true
    var key = ""
    var value = ""
}

enum ApiAuthKind: String, CaseIterable, Codable {
    case none, basic, bearer, apiKey

    var label: String {
        switch self {
        case .none: return "None"
        case .basic: return "Basic"
        case .bearer: return "Bearer"
        case .apiKey: return "API Key"
        }
    }
}

/// Auth block metadata. The kind, the Basic username, and the API-key
/// header name stay in the request JSON; the password, bearer token, and
/// key value live in the Keychain (see `ApiAuthSecrets` / `MDMSecrets`).
/// `password`, `token`, and `key` below are legacy decode-only holders:
/// old files decode through them once for the Keychain migration, and
/// they stay empty at rest afterwards. Never read them when sending.
struct ApiAuth: Codable, Equatable {
    var kind: ApiAuthKind = .none
    var username = ""
    var password = ""
    var token = ""
    var headerName = "X-API-Key"
    var key = ""
}

enum ApiBodyKind: String, CaseIterable, Codable {
    case json, text, form

    var label: String {
        switch self {
        case .json: return "JSON"
        case .text: return "Teks"
        case .form: return "Form"
        }
    }

    var contentType: String {
        switch self {
        case .json: return "application/json"
        case .text: return "text/plain"
        case .form: return "application/x-www-form-urlencoded"
        }
    }
}

/// The last response of a saved request, persisted so the request
/// list and the AI tab can show what the API actually returned.
/// The body is capped at 8000 characters on save.
struct ApiLastResponse: Codable, Equatable {
    var status: Int?
    var durationMs: Int = 0
    var size: Int = 0
    var headers: [String: String] = [:]
    var body = ""
    var error: String?
    var ranAt = Date()
}

struct ApiRequest: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var method: ApiMethod = .get
    var url = ""
    var query: [ApiKeyValue] = []
    var headers: [ApiKeyValue] = []
    var auth = ApiAuth()
    var bodyKind: ApiBodyKind = .json
    var body = ""
    var cookiesEnabled = true
    var lastResponse: ApiLastResponse?

    static func fresh(number: Int) -> ApiRequest {
        ApiRequest(name: "New Request \(number)")
    }
}

/// A response that was just received; not persisted directly, it is
/// converted into ApiLastResponse when the request is saved.
struct ApiResponse {
    var status: Int?
    var durationMs: Int = 0
    var size: Int = 0
    var headers: [(String, String)] = []
    var bodyText = ""
    var error: String?
}

// MARK: - Store

@MainActor
final class ApiTesterStore: ObservableObject {
    @Published var saved: [ApiRequest] = []
    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = docs.appendingPathComponent("mdm-api-requests.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ApiRequest].self, from: data) {
            saved = decoded
            // S4: plaintext auth secrets from older saves move to the
            // Keychain once (keyed by each request's stable id).
            var migrated = false
            for i in saved.indices {
                if MDMSecrets.migrateApiRequest(&saved[i]) { migrated = true }
            }
            if migrated { save() }
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func upsert(_ request: ApiRequest) {
        if let index = saved.firstIndex(where: { $0.id == request.id }) {
            saved[index] = request
        } else {
            saved.append(request)
        }
        save()
    }

    func remove(at offsets: IndexSet) {
        saved.remove(atOffsets: offsets)
        save()
    }

    var nextNumber: Int {
        let numbers = saved.compactMap { request -> Int? in
            let parts = request.name.split(separator: " ")
            guard parts.count == 3, parts[0] == "New", parts[1] == "Request",
                  let n = Int(parts[2]) else { return nil }
            return n
        }
        return (numbers.max() ?? 0) + 1
    }
}

// MARK: - Sending

extension ApiTesterView {
    /// Sends a request. `secrets` is the in-memory auth secret the view is
    /// editing; when nil (the AI agent tool path) the secret is loaded
    /// from the Keychain by the request's id. The plaintext fields on
    /// `ApiAuth` are never read here — they are legacy decode holders.
    static func send(_ request: ApiRequest, secrets: ApiAuthSecrets? = nil) async -> ApiResponse {
        let secrets = secrets ?? MDMSecrets.loadApiSecrets(for: request.id)
        var urlString = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.contains("://") { urlString = "https://" + urlString }
        guard var components = URLComponents(string: urlString) else {
            return ApiResponse(error: "URL tidak valid.")
        }
        var items = components.queryItems ?? []
        items.append(contentsOf: request.query
            .filter { $0.enabled && !$0.key.isEmpty }
            .map { URLQueryItem(name: $0.key, value: $0.value) })
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else {
            return ApiResponse(error: "URL tidak valid.")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        // Auth first, then the user's own headers win on duplicates.
        switch request.auth.kind {
        case .basic:
            let creds = Data("\(request.auth.username):\(secrets.password)".utf8).base64EncodedString()
            urlRequest.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
        case .bearer:
            urlRequest.setValue("Bearer \(secrets.token)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            if !request.auth.headerName.isEmpty {
                urlRequest.setValue(secrets.key, forHTTPHeaderField: request.auth.headerName)
            }
        case .none:
            break
        }
        for header in request.headers where header.enabled && !header.key.isEmpty {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.key)
        }
        if request.method.allowsBody {
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue(request.bodyKind.contentType, forHTTPHeaderField: "Content-Type")
            }
            urlRequest.httpBody = Data(request.body.utf8)
        }

        // Shared session keeps the system cookie jar (cookies on);
        // an ephemeral session sends and accepts no cookies.
        let session: URLSession
        if request.cookiesEnabled {
            session = URLSession.shared
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            session = URLSession(configuration: config)
        }

        let start = Date()
        do {
            let (data, urlResponse) = try await session.data(for: urlRequest)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let http = urlResponse as? HTTPURLResponse
            var headers: [(String, String)] = []
            if let http {
                for (key, value) in http.allHeaderFields {
                    headers.append(("\(key)", "\(value)"))
                }
                headers.sort { $0.0 < $1.0 }
            }
            return ApiResponse(
                status: http?.statusCode,
                durationMs: ms,
                size: data.count,
                headers: headers,
                bodyText: Self.prettyBody(data, contentType: http?.value(forHTTPHeaderField: "Content-Type"))
            )
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if error is CancellationError {
                return ApiResponse(durationMs: ms, error: "Dibatalkan.")
            }
            return ApiResponse(durationMs: ms, error: (error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
    }

    /// JSON responses are pretty-printed; anything else is shown as
    /// text, capped so a huge body cannot flood the screen.
    static func prettyBody(_ data: Data, contentType: String?) -> String {
        let capped = data.prefix(200_000)
        let note = data.count > 200_000 ? "\n…(dipotong, total \(data.count) byte)" : ""
        if let json = try? JSONSerialization.jsonObject(with: capped),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            return text + note
        }
        if let text = String(data: capped, encoding: .utf8) {
            return text + note
        }
        return "(respons biner, \(data.count) byte)"
    }

    static func formatByteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func statusText(_ code: Int) -> String {
        "\(code) \(HTTPURLResponse.localizedString(forStatusCode: code))"
    }

    static func statusTone(_ code: Int?) -> MDMStatusTone {
        guard let code else { return .muted }
        switch code {
        case 200..<300: return .success
        case 300..<400: return .accent
        case 400..<500: return .warning
        default: return .error
        }
    }
}

// MARK: - View

struct ApiTesterView: View {
    @EnvironmentObject var store: DownloadStore
    @StateObject private var apiStore = ApiTesterStore()
    @State private var draft: ApiRequest
    @State private var secretDraft = ApiAuthSecrets()
    @State private var response: ApiResponse?
    @State private var sending = false
    @State private var sendTask: Task<Void, Never>?

    init() {
        _draft = State(initialValue: ApiRequest.fresh(number: 1))
    }

    /// Loads the Keychain secret for the draft being edited. Called
    /// whenever the draft is replaced (open, history tap, "Baru").
    private func refreshSecrets() {
        secretDraft = MDMSecrets.loadApiSecrets(for: draft.id)
    }

    var body: some View {
        // No own NavigationStack: in the tab bar the system
        // (Lainnya overflow) navigation already provides the bar —
        // a second stack put the title on a second bar far below
        // the back button. The title and Baru button now sit on
        // the same bar as the back button.
        List {
                requestSection
                querySection
                headersSection
                authSection
                if draft.method.allowsBody { bodySection }
                sendSection
                if let response { responseSection(response) }
                historySection
            }
            .toolbar {
                ToolbarItem(placement: .principal) { Text("API Tester") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Baru") {
                        sendTask?.cancel()
                        sending = false
                        response = nil
                        draft = ApiRequest.fresh(number: apiStore.nextNumber)
                        secretDraft = ApiAuthSecrets()
                    }
                }
            }
            .onAppear { store.apiTester = apiStore; refreshSecrets() }
            .scrollContentBackground(.hidden)
            .background(Color.mdmBackground)
    }

    // MARK: Sections

    private var requestSection: some View {
        Section("Permintaan") {
            TextField("Nama", text: $draft.name)
            TextField("URL, mis. https://api.contoh.com/data", text: $draft.url)
                .font(.system(.body, design: .monospaced))
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Picker("Method", selection: $draft.method) {
                ForEach(ApiMethod.allCases, id: \.self) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var querySection: some View {
        Section("Query") {
            ForEach($draft.query) { $item in
                keyValueRow(item: $item, keyPlaceholder: "nama", valuePlaceholder: "nilai")
            }
            .onDelete { draft.query.remove(atOffsets: $0) }
            Button("Tambah Parameter") {
                draft.query.append(ApiKeyValue())
            }
        }
    }

    private var headersSection: some View {
        Section("Headers") {
            ForEach($draft.headers) { $item in
                keyValueRow(item: $item, keyPlaceholder: "nama header", valuePlaceholder: "nilai")
            }
            .onDelete { draft.headers.remove(atOffsets: $0) }
            Button("Tambah Header") {
                draft.headers.append(ApiKeyValue())
            }
        }
    }

    private var authSection: some View {
        Section("Auth") {
            Picker("Jenis", selection: $draft.auth.kind) {
                ForEach(ApiAuthKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            switch draft.auth.kind {
            case .basic:
                TextField("Username", text: $draft.auth.username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                SecureField("Password", text: Binding(get: { secretDraft.password }, set: { secretDraft.password = $0 }))
            case .bearer:
                SecureField("Token", text: Binding(get: { secretDraft.token }, set: { secretDraft.token = $0 }))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            case .apiKey:
                TextField("Nama header", text: $draft.auth.headerName)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                SecureField("API key", text: Binding(get: { secretDraft.key }, set: { secretDraft.key = $0 }))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            case .none:
                EmptyView()
            }
            if draft.auth.kind != .none {
                if !secretDraft.isEmpty {
                    Text("Rahasia tersimpan di Keychain dan tidak pernah ditampilkan. Mengosongkan kolom lalu mengirim akan menghapusnya.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Hapus rahasia tersimpan", role: .destructive) {
                        secretDraft = ApiAuthSecrets()
                        MDMSecrets.deleteApiSecrets(for: draft.id)
                    }
                    .font(.subheadline)
                } else {
                    Text("Rahasia disimpan di Keychain saat request dikirim, tidak pernah di file JSON.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var bodySection: some View {
        Section("Body") {
            Picker("Jenis", selection: $draft.bodyKind) {
                ForEach(ApiBodyKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            TextEditor(text: $draft.body)
                .font(.system(.body, design: .monospaced))
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .frame(minHeight: 120)
        }
    }

    private var sendSection: some View {
        Section {
            Toggle("Kirim & terima cookie", isOn: $draft.cookiesEnabled)
            if sending {
                HStack {
                    ProgressView()
                    Text("Mengirim…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Batalkan") {
                        sendTask?.cancel()
                        sending = false
                    }
                }
            } else {
                MDMPrimaryButton(title: "Kirim", systemImage: "play.fill") {
                    sendTapped()
                }
                .disabled(draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func responseSection(_ response: ApiResponse) -> some View {
        Section("Respons") {
            if let error = response.error {
                Text(error)
                    .foregroundStyle(.red)
            } else if let status = response.status {
                HStack(spacing: 8) {
                    MDMStatusBadge(text: Self.statusText(status), tone: Self.statusTone(status))
                    Spacer()
                    Text("\(response.durationMs) ms")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(Self.formatByteCount(response.size))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !response.headers.isEmpty {
                    DisclosureGroup("Header (\(response.headers.count))") {
                        ForEach(response.headers.indices, id: \.self) { index in
                            let header = response.headers[index]
                            HStack(alignment: .top) {
                                Text(header.0)
                                    .font(.caption).bold()
                                Spacer()
                                Text(header.1)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    .font(.subheadline)
                }
                if !response.bodyText.isEmpty {
                    Text(response.bodyText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var historySection: some View {
        Section("Riwayat") {
            if apiStore.saved.isEmpty {
                Text("Belum ada permintaan tersimpan. Kirim satu, dan dia tersimpan di sini.")
                    .foregroundStyle(.secondary)
            }
            ForEach(apiStore.saved) { saved in
                Button {
                    sendTask?.cancel()
                    sending = false
                    response = nil
                    draft = saved
                    refreshSecrets()
                } label: {
                    HStack(spacing: 8) {
                        Text(saved.method.rawValue)
                            .font(.system(.caption, design: .monospaced)).bold()
                            .foregroundStyle(saved.method.tint)
                            .frame(width: 56, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(saved.name)
                                .foregroundStyle(.primary)
                            Text(saved.url.isEmpty ? "(belum ada URL)" : saved.url)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let last = saved.lastResponse, let status = last.status {
                            MDMStatusBadge(text: "\(status)", tone: Self.statusTone(status))
                        }
                    }
                }
            }
            .onDelete { apiStore.remove(at: $0) }
        }
    }

    // MARK: Rows

    private func keyValueRow(item: Binding<ApiKeyValue>, keyPlaceholder: String, valuePlaceholder: String) -> some View {
        HStack(spacing: 8) {
            Button {
                item.enabled.wrappedValue.toggle()
            } label: {
                Image(systemName: item.enabled.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.enabled.wrappedValue ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            TextField(keyPlaceholder, text: item.key)
                .autocapitalization(.none)
                .autocorrectionDisabled()
            TextField(valuePlaceholder, text: item.value)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Sending

    private func sendTapped() {
        sendTask?.cancel()
        let request = draft
        let secrets = secretDraft
        sendTask = Task {
            sending = true
            response = nil
            let result = await Self.send(request, secrets: secrets)
            sending = false
            response = result
            MDMSecrets.saveApiSecrets(secrets, for: request.id)
            var updated = request
            updated.lastResponse = ApiLastResponse(
                status: result.status,
                durationMs: result.durationMs,
                size: result.size,
                headers: Dictionary(result.headers, uniquingKeysWith: { first, _ in first }),
                body: String(result.bodyText.prefix(8000)),
                error: result.error,
                ranAt: Date()
            )
            draft = updated
            apiStore.upsert(updated)
        }
    }
}

