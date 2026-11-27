import Foundation
import SwiftUI

// MARK: - Model discovery: read the model list from the provider's own
// base URL (GET .../models), and user-added custom models.
//
// Every provider the app talks to publishes a list endpoint: OpenAI-shape
// gateways (ChatGPT, Balitech, any Custom endpoint) expose GET
// {base}/models, Gemini exposes GET /v1beta/models, Claude exposes GET
// /v1/models. The fetched ids are cached in BrowserSettings
// (aiDiscoveredModels) so the picker works offline; "Muat model dari
// server" refreshes them. Custom models (aiCustomModels) are the
// user's own ids, unlimited in count, and appear in the same picker.
// The built-in catalogs stay as the fallback: a gateway that answers
// /models with an error simply keeps the catalog + custom lists.

enum ModelDiscovery {
    enum DiscoveryError: Error {
        case noEndpoint
        case http(Int)
        case network(Error)
        case invalidResponse
        var message: String {
            switch self {
            case .noEndpoint:
                return "URL dasar endpoint-nya kosong atau tidak valid."
            case .http(let code) where code == 401 || code == 403:
                return "Server menolak (HTTP \(code)): kunci belum disimpan atau tidak valid untuk endpoint ini."
            case .http(let code) where code == 404:
                return "Server tidak punya daftar model (HTTP 404): endpoint ini tidak menyediakan GET /models."
            case .http(let code):
                return "Server menjawab HTTP \(code)."
            case .network:
                return "Tidak bisa mencapai server. Periksa koneksi, lalu coba lagi."
            case .invalidResponse:
                return "Jawaban server tidak bisa dibaca sebagai daftar model."
            }
        }
    }

    /// The list-models URL for a provider. Custom endpoints accept a
    /// bare base URL or a full /chat/completions URL, like the chat
    /// requests do; "/models" and "/chat/completions" suffixes are
    /// stripped before "/models" is appended.
    static func listURL(provider: AIProvider, endpoint: String) -> URL? {
        switch provider {
        case .gemini:
            return URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")
        case .claude:
            return URL(string: "https://api.anthropic.com/v1/models?limit=200")
        case .chatgpt:
            return URL(string: "https://api.openai.com/v1/models")
        case .balitech:
            return URL(string: AIProvider.balitechBaseURL + "/models")
        case .custom:
            var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") { base.removeLast() }
            guard !base.isEmpty else { return nil }
            if base.hasSuffix("/chat/completions") {
                base = String(base.dropLast("/chat/completions".count))
            }
            if base.hasSuffix("/models") {
                base = String(base.dropLast("/models".count))
            }
            while base.hasSuffix("/") { base.removeLast() }
            return URL(string: base + "/models")
        case .meta:
            return nil
        }
    }

    /// Fetch the provider's model ids. The key may be empty: some
    /// gateways list models without auth, and the HTTP error then says
    /// so plainly instead of the app refusing to try.
    static func fetch(provider: AIProvider, endpoint: String, apiKey: String,
                      completion: @escaping (Result<[String], DiscoveryError>) -> Void) {
        guard let url = listURL(provider: provider, endpoint: endpoint) else {
            completion(.failure(.noEndpoint))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .gemini:
            if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        case .claude:
            if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-api-key") }
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .chatgpt, .balitech, .custom:
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .meta:
            completion(.failure(.noEndpoint))
            return
        }
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(.network(error)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.invalidResponse))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(.http(http.statusCode)))
                return
            }
            guard let data,
                  let ids = parse(data: data, provider: provider) else {
                completion(.failure(.invalidResponse))
                return
            }
            completion(.success(ids))
        }.resume()
    }

    /// Parse a list-models payload into sorted, de-duplicated ids.
    /// OpenAI-shape and Claude share {"data":[{"id":...}]}; Gemini uses
    /// {"models":[{"name":"models/xxx","supportedGenerationMethods":[...]}]}
    /// and only generateContent-capable models can answer chats.
    static func parse(data: Data, provider: AIProvider) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var ids: [String] = []
        if provider == .gemini {
            guard let models = json["models"] as? [[String: Any]] else { return nil }
            for m in models {
                guard let name = m["name"] as? String else { continue }
                let methods = m["supportedGenerationMethods"] as? [String] ?? []
                guard methods.contains("generateContent") else { continue }
                ids.append(name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name)
            }
        } else {
            guard let list = json["data"] as? [[String: Any]] else { return nil }
            for item in list {
                if let id = item["id"] as? String, !id.isEmpty { ids.append(id) }
            }
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.sorted()
    }
}

// MARK: - Catalog + discovered + custom ids, shared by both AI surfaces

/// One built-in catalog entry: the server id plus the friendly name
/// shown in the picker.
struct CatalogEntry: Hashable {
    let id: String
    let name: String
}

extension AIProvider {
    /// The one "type it yourself" picker tag, shared by every provider.
    /// (The per-provider *CustomTag constants are the same value and
    /// stay for the older call sites.)
    static let modelCustomTag = "__kustom__"

    /// Built-in catalog entries (id + friendly name) for this provider.
    /// Custom has no catalog: its models come only from the server or
    /// from the user's own list.
    var catalogEntries: [CatalogEntry] {
        switch self {
        case .balitech: return Self.balitechModels.map { CatalogEntry(id: $0.id, name: $0.name) }
        case .gemini: return Self.geminiModels.map { CatalogEntry(id: $0.id, name: $0.name) }
        case .chatgpt: return Self.chatgptModels.map { CatalogEntry(id: $0.id, name: $0.name) }
        case .claude: return Self.claudeModels.map { CatalogEntry(id: $0.id, name: $0.name) }
        case .custom, .meta: return []
        }
    }

    var catalogIDs: [String] { catalogEntries.map(\.id) }

    /// Every id the picker knows for this provider: catalog first, then
    /// server-discovered, then the user's custom ids (catalog ids are
    /// never repeated in the later sections).
    static func knownModelIDs(for provider: AIProvider, settings: BrowserSettings) -> [String] {
        var ids = provider.catalogIDs
        var seen = Set(ids)
        for id in settings.aiDiscoveredModels[provider.rawValue] ?? [] where seen.insert(id).inserted {
            ids.append(id)
        }
        for id in settings.aiCustomModels[provider.rawValue] ?? [] where seen.insert(id).inserted {
            ids.append(id)
        }
        return ids
    }

    /// Picker selection: a known id selects its row, anything else
    /// selects "Kustom…" and keeps the free-text field visible.
    static func modelPickerBinding(model: Binding<String>, known: [String]) -> Binding<String> {
        Binding(
            get: { known.contains(model.wrappedValue) ? model.wrappedValue : modelCustomTag },
            set: { if $0 != modelCustomTag { model.wrappedValue = $0 } }
        )
    }
}
