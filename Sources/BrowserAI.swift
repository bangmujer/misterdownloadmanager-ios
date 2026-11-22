import SwiftUI
import Foundation
import Security
import UIKit

// MARK: - Ask AI providers
//
// Gemini, ChatGPT and Claude are reached through each provider's own
// public API with the user's own key. Meta does not publish a public API
// for the Meta AI assistant, so "Muse" is an honest web hand-off: it
// opens meta.ai in a new tab and copies the question + page context for
// pasting. It is labelled that way in the UI and never fakes an answer.

enum AIProvider: String, CaseIterable, Identifiable {
    case gemini = "Gemini"
    case chatgpt = "ChatGPT"
    case claude = "Claude"
    case meta = "Muse"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var needsKey: Bool { self != .meta }

    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-2.0-flash"
        case .chatgpt: return "gpt-4o-mini"
        case .claude: return "claude-3-5-haiku-20241022"
        case .meta: return ""
        }
    }

    var keyURL: String? {
        switch self {
        case .gemini: return "https://aistudio.google.com/apikey"
        case .chatgpt: return "https://platform.openai.com/api-keys"
        case .claude: return "https://console.anthropic.com/settings/keys"
        case .meta: return nil
        }
    }

    var keyInfo: String {
        switch self {
        case .gemini: return "Gratis (ada limit harian) — ambil di Google AI Studio."
        case .chatgpt: return "Berbayar — butuh saldo di akun OpenAI."
        case .claude: return "Berbayar — butuh saldo di akun Anthropic."
        case .meta: return "Meta tidak menyediakan API publik untuk asisten Meta AI."
        }
    }
}

// MARK: - Keychain storage for API keys (never in the settings JSON file)

enum KeychainHelper {
    static let service = "com.bangmujer.misterdownloadmanager.ai-keys"

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Streaming AI client (SSE for all three APIs)

enum AIClient {
    static func ask(provider: AIProvider, model: String, apiKey: String,
                    question: String, pageTitle: String, pageURL: String, pageText: String,
                    onToken: @escaping (String) -> Void,
                    onDone: @escaping (String?) -> Void) {
        let prompt = buildPrompt(question: question, pageTitle: pageTitle, pageURL: pageURL, pageText: pageText)
        guard let request = makeRequest(provider: provider, model: model, apiKey: apiKey, prompt: prompt) else {
            onDone("Tidak bisa membuat permintaan untuk \(provider.displayName).")
            return
        }
        stream(request: request, provider: provider, onToken: onToken, onDone: onDone)
    }

    private static func buildPrompt(question: String, pageTitle: String, pageURL: String, pageText: String) -> String {
        var parts: [String] = []
        parts.append("Kamu adalah asisten AI di dalam browser. Jawablah dalam bahasa yang sama dengan pertanyaan pengguna.")
        parts.append("Halaman yang sedang dibuka:\nJudul: \(pageTitle)\nURL: \(pageURL)")
        let trimmed = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            parts.append("Isi halaman: (tidak ada teks yang bisa dibaca dari halaman ini)")
        } else {
            parts.append("Isi halaman (dipotong):\n\(pageText)")
        }
        parts.append("Pertanyaan pengguna: \(question)")
        return parts.joined(separator: "\n\n")
    }

    private static func makeRequest(provider: AIProvider, model: String, apiKey: String, prompt: String) -> URLRequest? {
        switch provider {
        case .gemini:
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)") else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["contents": [["parts": [["text": prompt]]]]])
            return req
        case .chatgpt:
            guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model, "stream": true,
                "messages": [["role": "user", "content": prompt]],
            ])
            return req
        case .claude:
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model, "max_tokens": 2048, "stream": true,
                "messages": [["role": "user", "content": prompt]],
            ])
            return req
        case .meta:
            return nil
        }
    }

    private static func stream(request: URLRequest, provider: AIProvider,
                               onToken: @escaping (String) -> Void,
                               onDone: @escaping (String?) -> Void) {
        Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    await MainActor.run { onDone("Respons tidak dikenal dari \(provider.displayName).") }
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    var body = ""
                    for try await line in bytes.lines { body += line + "\n" }
                    let snippet = String(body.prefix(300))
                    await MainActor.run { onDone("Error HTTP \(http.statusCode) dari \(provider.displayName): \(snippet)") }
                    return
                }
                for try await line in bytes.lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("data:") else { continue }
                    let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let text = extractDelta(provider: provider, json: json),
                          !text.isEmpty else { continue }
                    let token = text
                    await MainActor.run { onToken(token) }
                }
                await MainActor.run { onDone(nil) }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { onDone(message) }
            }
        }
    }

    private static func extractDelta(provider: AIProvider, json: [String: Any]) -> String? {
        switch provider {
        case .gemini:
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let text = firstPart["text"] as? String else { return nil }
            return text
        case .chatgpt:
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any],
                  let text = delta["content"] as? String else { return nil }
            return text
        case .claude:
            guard let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return text
        case .meta:
            return nil
        }
    }
}

// MARK: - Ask AI sheet

struct AskAIView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    var pageTitle: String
    var pageURL: String
    var pageText: String
    var onOpenURL: (URL) -> Void

    @State private var provider: AIProvider = .gemini
    @State private var model = ""
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var question = ""
    @State private var answer = ""
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var copiedNotice = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !pageTitle.isEmpty || !pageURL.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pageTitle.isEmpty ? "Halaman ini" : pageTitle)
                                .font(.headline).lineLimit(2)
                            Text(pageURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(pageText.isEmpty ? "Teks halaman tidak terbaca." : "Konteks halaman terbaca (\(pageText.count) karakter).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("AI").font(.headline)
                        Picker("AI", selection: $provider) {
                            ForEach(AIProvider.allCases) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(provider.keyInfo).font(.caption).foregroundStyle(.secondary)
                    }

                    if provider == .meta {
                        metaCard
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Model").font(.headline)
                            TextField("Model", text: $model)
                                .autocapitalization(.none).autocorrectionDisabled()
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                            Text("API key").font(.headline)
                            SecureField("API key \(provider.displayName)", text: $apiKey)
                                .autocapitalization(.none).autocorrectionDisabled()
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                            HStack(spacing: 10) {
                                Button("Simpan kunci") {
                                    KeychainHelper.save(account: provider.rawValue, value: apiKey)
                                    keySaved = true
                                }
                                .disabled(apiKey.isEmpty)
                                if keySaved {
                                    Button("Hapus kunci", role: .destructive) {
                                        KeychainHelper.delete(account: provider.rawValue)
                                        apiKey = ""
                                        keySaved = false
                                    }
                                }
                                Spacer()
                                if keySaved {
                                    Label("Tersimpan di Keychain", systemImage: "lock.fill")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .font(.subheadline)
                            if let keyURL = provider.keyURL, let url = URL(string: keyURL) {
                                Link("Dapatkan API key \(provider.displayName)…", destination: url)
                                    .font(.subheadline)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pertanyaan").font(.headline)
                        TextEditor(text: $question)
                            .frame(minHeight: 80)
                            .padding(8)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        HStack(spacing: 8) {
                            quickAction("Ringkas halaman ini")
                            quickAction("Jelaskan sederhana")
                        }
                        HStack(spacing: 8) {
                            quickAction("Apa isi halaman ini?")
                        }
                        Button {
                            send()
                        } label: {
                            HStack {
                                if isLoading { ProgressView().tint(.white) }
                                Text(isLoading ? "Menjawab…" : "Tanya \(provider.displayName)")
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                        }
                        .disabled(isLoading || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (provider.needsKey && apiKey.isEmpty))
                    }

                    if let errorText {
                        Text(errorText).font(.subheadline).foregroundStyle(.red)
                    }
                    if !answer.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Jawaban").font(.headline)
                            Text(answer)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    } else if isLoading {
                        HStack { ProgressView(); Text("Meminta jawaban…").foregroundStyle(.secondary) }
                            .font(.subheadline)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Minta AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Selesai") { dismiss() } } }
        }
        .onAppear {
            provider = AIProvider(rawValue: store.browserSettings.aiProvider) ?? .gemini
            loadModelAndKey()
        }
        .onChange(of: provider) { newValue in
            store.browserSettings.aiProvider = newValue.rawValue
            store.saveBrowserSettings()
            answer = ""
            errorText = nil
            loadModelAndKey()
        }
        .onChange(of: model) { newValue in
            store.browserSettings.aiModels[provider.rawValue] = newValue
            store.saveBrowserSettings()
        }
    }

    private func quickAction(_ text: String) -> some View {
        Button(text) {
            question = text
            send()
        }
        .font(.subheadline)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .disabled(isLoading || (provider.needsKey && apiKey.isEmpty))
    }

    private func loadModelAndKey() {
        model = store.browserSettings.aiModels[provider.rawValue] ?? provider.defaultModel
        let saved = KeychainHelper.load(account: provider.rawValue) ?? ""
        apiKey = saved
        keySaved = !saved.isEmpty
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isLoading else { return }
        guard provider != .meta else { return }
        guard !apiKey.isEmpty else {
            errorText = "Masukkan API key \(provider.displayName) dulu — kuncinya disimpan di Keychain perangkat ini."
            return
        }
        guard !model.isEmpty else {
            errorText = "Isi nama model dulu."
            return
        }
        isLoading = true
        answer = ""
        errorText = nil
        AIClient.ask(
            provider: provider, model: model, apiKey: apiKey,
            question: q, pageTitle: pageTitle, pageURL: pageURL, pageText: pageText,
            onToken: { token in answer += token },
            onDone: { message in
                isLoading = false
                if let message {
                    errorText = message
                } else if answer.isEmpty {
                    errorText = "Tidak ada jawaban dari \(provider.displayName). Coba cek model dan kunci API-nya."
                }
            }
        )
    }

    private var metaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Muse lewat web", systemImage: "info.circle").font(.headline)
            Text("Meta tidak menyediakan API publik untuk asisten Meta AI, jadi jawaban Muse tidak bisa ditampilkan di dalam app ini. Yang bisa dilakukan: buka meta.ai di tab baru, dan pertanyaan + konteks halaman disalin supaya tinggal tempel.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Buka meta.ai") {
                    if let url = URL(string: "https://www.meta.ai/") {
                        dismiss()
                        onOpenURL(url)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
                Button("Salin prompt") {
                    UIPasteboard.general.string = metaPrompt()
                    copiedNotice = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedNotice = false }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: Capsule())
                if copiedNotice {
                    Text("Disalin.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func metaPrompt() -> String {
        var parts: [String] = []
        if !pageTitle.isEmpty { parts.append("Halaman: \(pageTitle)") }
        if !pageURL.isEmpty { parts.append("URL: \(pageURL)") }
        if !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Isi halaman:\n\(pageText)")
        }
        parts.append("Pertanyaan: \(question.isEmpty ? "Ringkas halaman ini." : question)")
        return parts.joined(separator: "\n\n")
    }
}
