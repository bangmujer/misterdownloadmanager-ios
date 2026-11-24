import SwiftUI
import Foundation
import Security
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Ask AI providers
//
// Gemini, ChatGPT and Claude are reached through each provider's own
// public API with the user's own key. "Custom" is any OpenAI-compatible
// chat/completions endpoint (the user's own proxy/gateway): same request
// shape as ChatGPT — POST, Bearer key, {"model","stream","messages"} —
// against a user-supplied base URL, with a user-supplied model name.
// Meta does not publish a public API
// for the Meta AI assistant, so "Muse" is an honest web hand-off: it
// opens meta.ai in a new tab and copies the question + page context for
// pasting. It is labelled that way in the UI and never fakes an answer.

enum AIProvider: String, CaseIterable, Identifiable {
    case gemini = "Gemini"
    case chatgpt = "ChatGPT"
    case claude = "Claude"
    case custom = "Custom"
    case meta = "Muse"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var needsKey: Bool { self != .meta }

    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-2.0-flash"
        case .chatgpt: return "gpt-4o-mini"
        case .claude: return "claude-3-5-haiku-20241022"
        case .custom: return "deepseek-v4.1-flash"
        case .meta: return ""
        }
    }

    var keyURL: String? {
        switch self {
        case .gemini: return "https://aistudio.google.com/apikey"
        case .chatgpt: return "https://platform.openai.com/api-keys"
        case .claude: return "https://console.anthropic.com/settings/keys"
        case .custom: return nil
        case .meta: return nil
        }
    }

    var keyInfo: String {
        switch self {
        case .gemini: return "Gratis (ada limit harian) — ambil di Google AI Studio."
        case .chatgpt: return "Berbayar — butuh saldo di akun OpenAI."
        case .claude: return "Berbayar — butuh saldo di akun Anthropic."
        case .custom: return "Endpoint sendiri yang kompatibel dengan OpenAI (format chat/completions). Isi URL dasar, model, dan API key di bawah."
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

// MARK: - Ask AI attachments (one photo or file per question)

/// A single attachment held in memory only for the life of the Ask AI
/// sheet — never written to disk or settings. Images are downscaled and
/// re-encoded as JPEG for vision-capable models; text files are read as
/// text into the prompt; PDFs go to the model as base64 documents where
/// the provider supports them; anything else reaches the model as name,
/// type and size only.
struct AIAttachment: Equatable {
    var fileName: String
    var mimeType: String
    var data: Data
    var isImage: Bool

    var displaySize: String {
        let kb = Double(data.count) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    var isPDF: Bool { mimeType == "application/pdf" }

    /// Readable text for the prompt, or nil for images, PDFs and binary
    /// files. Extension-less text and code files are covered by the
    /// UTF-8 decode + NUL check, not by the MIME type alone.
    var readableText: String? {
        if isImage || isPDF { return nil }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return nil }
        if text.count > 60_000 { return String(text.prefix(60_000)) + "\n... (dipotong — file lebih panjang dari ini)" }
        return text
    }

    static func fromPickedData(fileName: String, data: Data) -> AIAttachment {
        if let image = UIImage(data: data) {
            return AIAttachment(fileName: fileName, mimeType: "image/jpeg", data: downscaledJPEG(image), isImage: true)
        }
        let ext = (fileName as NSString).pathExtension.lowercased()
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        return AIAttachment(fileName: fileName, mimeType: mime, data: data, isImage: false)
    }

    private static func downscaledJPEG(_ image: UIImage) -> Data {
        let maxEdge: CGFloat = 1568
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxEdge else {
            return image.jpegData(compressionQuality: 0.85) ?? Data()
        }
        let scale = maxEdge / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.85) ?? Data()
    }
}

/// UIKit pickers presented from the top view controller. SwiftUI's
/// `.fileImporter` silently drops selections when presented from a
/// sheet, and the Ask AI sheet is itself presented from the browser —
/// the same reason the extension import uses a UIKit presenter.
private final class AIAttachmentPicker: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    private var onImage: ((Data, String) -> Void)?
    private var onFile: ((URL) -> Void)?

    func presentPhoto(onPick: @escaping (Data, String) -> Void) {
        onImage = onPick
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        Self.topViewController()?.present(picker, animated: true)
    }

    func presentFile(onPick: @escaping (URL) -> Void) {
        onFile = onPick
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        Self.topViewController()?.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let pick = onImage
        onImage = nil
        guard let result = results.first else { return }
        let provider = result.itemProvider
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data else { return }
            DispatchQueue.main.async { pick?(data, "foto.jpg") }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let pick = onFile
        onFile = nil
        controller.dismiss(animated: true)
        guard let url = urls.first else { return }
        pick?(url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onFile = nil
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

// MARK: - Streaming AI client (SSE for all three APIs)

enum AIClient {
    static func ask(provider: AIProvider, model: String, apiKey: String, endpoint: String = "",
                    attachment: AIAttachment? = nil,
                    question: String, pageTitle: String, pageURL: String, pageText: String,
                    onToken: @escaping (String) -> Void,
                    onDone: @escaping (String?) -> Void) {
        let prompt = buildPrompt(question: question, pageTitle: pageTitle, pageURL: pageURL, pageText: pageText, attachment: attachment)
        guard let request = makeRequest(provider: provider, model: model, apiKey: apiKey, endpoint: endpoint, attachment: attachment, prompt: prompt) else {
            onDone("Tidak bisa membuat permintaan untuk \(provider.displayName).")
            return
        }
        stream(request: request, provider: provider, onToken: onToken, onDone: onDone)
    }

    /// Multi-turn chat for the dedicated AI tab: the whole recent
    /// history (roles "user"/"assistant", oldest first) is sent, so the
    /// model keeps context across turns. Same streaming path as `ask`.
    static func askChat(provider: AIProvider, model: String, apiKey: String, endpoint: String = "",
                        attachment: AIAttachment? = nil,
                        messages: [(role: String, text: String)],
                        onToken: @escaping (String) -> Void,
                        onDone: @escaping (String?) -> Void) {
        guard let request = makeChatRequest(provider: provider, model: model, apiKey: apiKey, endpoint: endpoint, attachment: attachment, messages: messages) else {
            onDone("Tidak bisa membuat permintaan untuk \(provider.displayName).")
            return
        }
        stream(request: request, provider: provider, onToken: onToken, onDone: onDone)
    }

    /// Text for the newest chat message when it carries an attachment.
    /// Images/PDFs ride as media parts (handled per provider in
    /// makeChatRequest), so the text stays as-is; readable text files
    /// and other binaries are described in the text itself, mirroring
    /// buildPrompt.
    private static func textWithAttachmentNote(_ text: String, attachment: AIAttachment?, mediaAttached: Bool) -> String {
        guard let attachment, !mediaAttached else { return text }
        if let readable = attachment.readableText {
            return text + "\n\nLampiran file \(attachment.fileName):\n\(readable)"
        }
        return text + "\n[Lampiran: file \(attachment.fileName) (\(attachment.mimeType), \(attachment.displaySize))]"
    }

    private static func makeChatRequest(provider: AIProvider, model: String, apiKey: String, endpoint: String, attachment: AIAttachment?, messages: [(role: String, text: String)]) -> URLRequest? {
        let system = "Kamu adalah asisten AI di dalam aplikasi Mister Download Manager. Jawablah dalam bahasa yang sama dengan pesan pengguna, ringkas tapi lengkap."
        let recent = Array(messages.suffix(20))
        let media = attachment.flatMap { $0.isImage || $0.isPDF ? $0 : nil }
        let lastText = textWithAttachmentNote(recent.last?.text ?? "", attachment: attachment, mediaAttached: media != nil)
        let lastIndex = max(0, recent.count - 1)
        switch provider {
        case .gemini:
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)") else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let contents: [[String: Any]] = recent.enumerated().map { idx, msg -> [String: Any] in
                var parts: [[String: Any]] = [["text": idx == lastIndex ? lastText : msg.text]]
                if idx == lastIndex, let media {
                    parts.append(["inline_data": ["mime_type": media.mimeType, "data": media.data.base64EncodedString()]])
                }
                return ["role": msg.role == "assistant" ? "model" : "user", "parts": parts]
            }
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": contents,
            ])
            return req
        case .chatgpt, .custom:
            // Same OpenAI chat/completions shape as makeRequest; Custom
            // just points it at the user's own base URL.
            let urlString: String
            if provider == .custom {
                guard let url = chatCompletionsURL(baseURL: endpoint) else { return nil }
                urlString = url.absoluteString
            } else {
                urlString = "https://api.openai.com/v1/chat/completions"
            }
            guard let url = URL(string: urlString) else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var apiMessages: [[String: Any]] = [["role": "system", "content": system]]
            apiMessages += recent.enumerated().map { idx, msg -> [String: Any] in
                if idx == lastIndex, let media {
                    let content: [[String: Any]]
                    if media.isImage {
                        content = [
                            ["type": "text", "text": lastText],
                            ["type": "image_url", "image_url": ["url": "data:\(media.mimeType);base64,\(media.data.base64EncodedString())"]],
                        ]
                    } else {
                        content = [
                            ["type": "text", "text": lastText],
                            ["type": "file", "file": ["filename": media.fileName, "file_data": "data:application/pdf;base64,\(media.data.base64EncodedString())"]],
                        ]
                    }
                    return ["role": msg.role, "content": content]
                }
                return ["role": msg.role, "content": idx == lastIndex ? lastText : msg.text]
            }
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model, "stream": true, "messages": apiMessages,
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
                "system": system,
                "messages": recent.enumerated().map { idx, msg -> [String: Any] in
                    if idx == lastIndex, let media {
                        let content: [[String: Any]]
                        if media.isImage {
                            content = [
                                ["type": "image", "source": ["type": "base64", "media_type": media.mimeType, "data": media.data.base64EncodedString()]],
                                ["type": "text", "text": lastText],
                            ]
                        } else {
                            content = [
                                ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": media.data.base64EncodedString()]],
                                ["type": "text", "text": lastText],
                            ]
                        }
                        return ["role": msg.role, "content": content]
                    }
                    return ["role": msg.role, "content": idx == lastIndex ? lastText : msg.text]
                },
            ])
            return req
        case .meta:
            return nil
        }
    }

    private static func buildPrompt(question: String, pageTitle: String, pageURL: String, pageText: String, attachment: AIAttachment?) -> String {
        var parts: [String] = []
        parts.append("Kamu adalah asisten AI di dalam browser. Jawablah dalam bahasa yang sama dengan pertanyaan pengguna.")
        parts.append("Halaman yang sedang dibuka:\nJudul: \(pageTitle)\nURL: \(pageURL)")
        let trimmed = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            parts.append("Isi halaman: (tidak ada teks yang bisa dibaca dari halaman ini)")
        } else {
            parts.append("Isi halaman (dipotong):\n\(pageText)")
        }
        if let attachment {
            if let text = attachment.readableText {
                parts.append("Lampiran file \(attachment.fileName):\n\(text)")
            } else if attachment.isImage {
                parts.append("Lampiran: foto bernama \(attachment.fileName), terlampir sebagai gambar — lihat gambarnya untuk menjawab.")
            } else if attachment.isPDF {
                parts.append("Lampiran: dokumen PDF bernama \(attachment.fileName), terlampir sebagai dokumen — baca isinya untuk menjawab.")
            } else {
                parts.append("Lampiran: file \(attachment.fileName) (\(attachment.mimeType), \(attachment.displaySize)) — isinya tidak bisa dibaca sebagai teks, hanya nama dan ukurannya yang diketahui.")
            }
        }
        parts.append("Pertanyaan pengguna: \(question)")
        return parts.joined(separator: "\n\n")
    }

    /// Accepts a base URL ("https://host/v3", trailing slash tolerated)
    /// or a full chat/completions URL, and returns the URL to POST to.
    private static func chatCompletionsURL(baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/chat/completions") { return URL(string: base) }
        return URL(string: base + "/chat/completions")
    }

    private static func makeRequest(provider: AIProvider, model: String, apiKey: String, endpoint: String, attachment: AIAttachment?, prompt: String) -> URLRequest? {
        switch provider {
        case .gemini:
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)") else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var parts: [[String: Any]] = [["text": prompt]]
            if let attachment, attachment.isImage || attachment.isPDF {
                parts.append(["inline_data": ["mime_type": attachment.mimeType, "data": attachment.data.base64EncodedString()]])
            }
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["contents": [["parts": parts]]])
            return req
        case .chatgpt, .custom:
            // Same OpenAI chat/completions shape; Custom just points it
            // at the user's own base URL instead of api.openai.com.
            let urlString: String
            if provider == .custom {
                guard let url = chatCompletionsURL(baseURL: endpoint) else { return nil }
                urlString = url.absoluteString
            } else {
                urlString = "https://api.openai.com/v1/chat/completions"
            }
            guard let url = URL(string: urlString) else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Plain string content when there is no media part (unchanged
            // behaviour); a parts array when an image/PDF rides along.
            let content: Any
            if let attachment, attachment.isImage {
                content = [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"]],
                ]
            } else if let attachment, attachment.isPDF {
                content = [
                    ["type": "text", "text": prompt],
                    ["type": "file", "file": ["filename": attachment.fileName, "file_data": "data:application/pdf;base64,\(attachment.data.base64EncodedString())"]],
                ]
            } else {
                content = prompt
            }
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model, "stream": true,
                "messages": [["role": "user", "content": content]],
            ])
            return req
        case .claude:
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let content: Any
            if let attachment, attachment.isImage {
                content = [
                    ["type": "image", "source": ["type": "base64", "media_type": attachment.mimeType, "data": attachment.data.base64EncodedString()]],
                    ["type": "text", "text": prompt],
                ]
            } else if let attachment, attachment.isPDF {
                content = [
                    ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": attachment.data.base64EncodedString()]],
                    ["type": "text", "text": prompt],
                ]
            } else {
                content = prompt
            }
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model, "max_tokens": 2048, "stream": true,
                "messages": [["role": "user", "content": content]],
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
        case .chatgpt, .custom:
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
    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var attachment: AIAttachment?
    @State private var attachmentPicker = AIAttachmentPicker()
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
                            if provider == .custom {
                                Text("Endpoint").font(.headline)
                                TextField("https://contoh.com/v3", text: $endpoint)
                                    .autocapitalization(.none).autocorrectionDisabled()
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                                Text("URL dasar endpoint-nya — boleh juga ditempel lengkap sampai /chat/completions. Permintaan dikirim persis seperti contoh curl: POST, header Authorization Bearer, body model + messages.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
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
                        if provider != .meta {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Lampiran").font(.headline)
                                if let attachment {
                                    HStack(spacing: 10) {
                                        if attachment.isImage, let uiImage = UIImage(data: attachment.data) {
                                            Image(uiImage: uiImage)
                                                .resizable().scaledToFill()
                                                .frame(width: 44, height: 44).clipped().cornerRadius(8)
                                        } else {
                                            Image(systemName: attachment.isPDF ? "doc.fill" : "doc")
                                                .font(.title2).foregroundStyle(.secondary)
                                                .frame(width: 44, height: 44)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(attachment.fileName).font(.subheadline).lineLimit(2)
                                            Text("\(attachment.displaySize) · \(attachment.isImage ? "foto" : attachment.isPDF ? "PDF" : attachment.mimeType)")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button { self.attachment = nil } label: {
                                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(10)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                                }
                                HStack(spacing: 8) {
                                    Button { pickPhoto() } label: { Label("Foto", systemImage: "photo") }
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(Color(.secondarySystemBackground), in: Capsule())
                                    Button { pickFile() } label: { Label("File", systemImage: "doc") }
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(Color(.secondarySystemBackground), in: Capsule())
                                }
                                .font(.subheadline)
                                Text("Satu lampiran per pertanyaan; pilih lagi untuk mengganti. Foto dikirim sebagai gambar, file teks dibaca isinya, PDF dikirim sebagai dokumen — semua tergantung model dan endpoint-nya mendukung atau tidak. Jenis file lain hanya terbaca nama dan ukurannya.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
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
                        .disabled(isLoading || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (provider.needsKey && apiKey.isEmpty) || missingEndpoint)
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
        .onChange(of: endpoint) { newValue in
            store.browserSettings.aiCustomEndpoint = newValue
            store.saveBrowserSettings()
        }
    }

    private var missingEndpoint: Bool {
        provider == .custom && endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func quickAction(_ text: String) -> some View {
        Button(text) {
            question = text
            send()
        }
        .font(.subheadline)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .disabled(isLoading || (provider.needsKey && apiKey.isEmpty) || missingEndpoint)
    }

    private func loadModelAndKey() {
        model = store.browserSettings.aiModels[provider.rawValue] ?? provider.defaultModel
        endpoint = store.browserSettings.aiCustomEndpoint
        let saved = KeychainHelper.load(account: provider.rawValue) ?? ""
        apiKey = saved
        keySaved = !saved.isEmpty
    }

    private func pickPhoto() {
        attachmentPicker.presentPhoto { data, name in
            guard data.count <= 30 * 1024 * 1024 else {
                errorText = "Foto terlalu besar (maks 30 MB)."
                return
            }
            attachment = AIAttachment.fromPickedData(fileName: name, data: data)
        }
    }

    private func pickFile() {
        attachmentPicker.presentFile { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                errorText = "File tidak bisa dibaca."
                return
            }
            guard data.count <= 20 * 1024 * 1024 else {
                errorText = "File terlalu besar (maks 20 MB)."
                return
            }
            attachment = AIAttachment.fromPickedData(fileName: url.lastPathComponent, data: data)
        }
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
        guard !missingEndpoint else {
            errorText = "Isi URL endpoint dulu."
            return
        }
        isLoading = true
        answer = ""
        errorText = nil
        AIClient.ask(
            provider: provider, model: model, apiKey: apiKey, endpoint: endpoint, attachment: attachment,
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

// MARK: - API key editor (Settings → AI → API Key)

/// The Settings AI section used to have no way to enter a key at all:
/// the only key field lived inside the Ask AI sheet. This editor puts
/// one next to the provider/model rows. Keys go to the Keychain only,
/// never to the settings JSON file.
struct AIKeyEditorView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    var provider: AIProvider

    @State private var apiKey = ""
    @State private var showKey = false
    @State private var keySaved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if provider == .meta {
                        Text("Meta tidak menyediakan API publik untuk asisten Meta AI, jadi tidak ada kunci yang perlu diisi.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Group {
                                if showKey {
                                    TextField("API key \(provider.displayName)", text: $apiKey)
                                } else {
                                    SecureField("API key \(provider.displayName)", text: $apiKey)
                                }
                            }
                            .autocapitalization(.none).autocorrectionDisabled()
                            Button {
                                showKey.toggle()
                            } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let keyURL = provider.keyURL, let url = URL(string: keyURL) {
                            Link("Dapatkan API key \(provider.displayName)…", destination: url)
                                .font(.subheadline)
                        }
                        if keySaved && !apiKey.isEmpty {
                            Label("Tersimpan di Keychain", systemImage: "lock.fill")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("API key \(provider.displayName)")
                } footer: {
                    Text("Kunci hanya tersimpan di Keychain perangkat ini — tidak pernah ditulis ke file pengaturan dan tidak pernah dikirim ke mana pun kecuali API provider yang dipilih.")
                }
                if provider != .meta {
                    Section {
                        Button("Simpan kunci") {
                            KeychainHelper.save(account: provider.rawValue, value: apiKey)
                            keySaved = true
                            store.objectWillChange.send()
                        }
                        .disabled(apiKey.isEmpty)
                        if keySaved {
                            Button("Hapus kunci", role: .destructive) {
                                KeychainHelper.delete(account: provider.rawValue)
                                apiKey = ""
                                keySaved = false
                                store.objectWillChange.send()
                            }
                        }
                    }
                }
            }
            .navigationTitle("API Key \(provider.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Selesai") { dismiss() } } }
            .onAppear {
                let saved = KeychainHelper.load(account: provider.rawValue) ?? ""
                apiKey = saved
                keySaved = !saved.isEmpty
            }
        }
    }
}
