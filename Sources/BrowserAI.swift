import SwiftUI
import Foundation
import Security
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import ZIPFoundation

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
    case balitech = "Balitech"
    case custom = "Custom"
    case meta = "Muse"

    /// Balitech's fixed gateway base URL — unlike Custom, the
    /// endpoint is not user-editable.
    static let balitechBaseURL = "https://balitechsolution.com/v3"

    /// One entry of the Balitech catalog (verified 2026-11-24 at
    /// https://balitechsolution.com/katalog-model/: 30 active models).
    /// The site states no per-model capability labels, so every entry
    /// is offered as a chat/completions model with no embeddings,
    /// vision, or image claims.
    struct BalitechModel: Hashable {
        let id: String
        let name: String
    }

    static let balitechModels: [BalitechModel] = [
        BalitechModel(id: "bt/deepseek-v4-flash", name: "DeepSeek V4 Flash"),
        BalitechModel(id: "bt/deepseek-v4-pro", name: "DeepSeek V4 Pro"),
        BalitechModel(id: "bt/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash"),
        BalitechModel(id: "bt/ernie-5.5-flash-preview", name: "ERNIE 5.5 Flash Preview"),
        BalitechModel(id: "bt/exaone-v2.5", name: "EXAONE v2.5"),
        BalitechModel(id: "bt/gemini-3.8-flash", name: "Gemini 3.8 Flash"),
        BalitechModel(id: "bt/glm-5.3-flash", name: "GLM-5.3 Flash"),
        BalitechModel(id: "bt/gpt-5.6-luna", name: "GPT 5.6 Luna"),
        BalitechModel(id: "bt/gpt-5.6-sol", name: "GPT 5.6 Sol"),
        BalitechModel(id: "bt/gpt-5.6-terra", name: "GPT 5.6 Terra"),
        BalitechModel(id: "bt/gpt-6-astra", name: "GPT 6 Astra"),
        BalitechModel(id: "bt/gpt-6-luna", name: "GPT 6 Luna"),
        BalitechModel(id: "bt/gpt-6-sol", name: "GPT 6 Sol"),
        BalitechModel(id: "bt/grok-4.7", name: "Grok 4.7"),
        BalitechModel(id: "bt/hy4-flash", name: "Hunyuan 4 Flash"),
        BalitechModel(id: "bt/kimi-k2.5", name: "Kimi K2.5"),
        BalitechModel(id: "bt/kimi-k3", name: "Kimi K3"),
        BalitechModel(id: "bt/ling-3.2-flash", name: "Ling 3.2 Flash"),
        BalitechModel(id: "bt/longcat-2.5", name: "LongCat 2.5"),
        BalitechModel(id: "bt/mercury-3", name: "Mercury 3"),
        BalitechModel(id: "bt/minimax-m3", name: "Minimax M3"),
        BalitechModel(id: "bt/minimax-m3.1-flash", name: "MiniMax M3.1 Flash"),
        BalitechModel(id: "bt/nemotron-3.5-super-vl", name: "Nemotron 3.5 Super VL"),
        BalitechModel(id: "bt/nex-n2.6", name: "Nex N2.6"),
        BalitechModel(id: "bt/qwen3.8-flash", name: "Qwen 3.8 Flash"),
        BalitechModel(id: "bt/qwen3.8-max", name: "Qwen 3.8 Max"),
        BalitechModel(id: "bt/qwen-4-max", name: "Qwen 4 Max"),
        BalitechModel(id: "bt/qwen3.8-27b", name: "Qwen3.8 27B"),
        BalitechModel(id: "bt/sensenova-6.8-flash", name: "SenseNova 6.8 Flash"),
        BalitechModel(id: "bt/step-5-preview", name: "Step 5 Preview"),
    ]

    /// Picker tag for the "type it yourself" row. Never stored as a
    /// model: when the stored model is not a catalog slug, the picker
    /// shows this row and the text field stays visible.
    static let balitechCustomTag = "__kustom__"

    static func isBalitechCatalogModel(_ id: String) -> Bool {
        balitechModels.contains(where: { $0.id == id })
    }

    /// Picker selection for the Balitech model dropdown: a catalog
    /// slug selects its row, anything else selects "Kustom…".
    static func balitechModelPickerBinding(model: Binding<String>) -> Binding<String> {
        Binding(
            get: { isBalitechCatalogModel(model.wrappedValue) ? model.wrappedValue : balitechCustomTag },
            set: { if $0 != balitechCustomTag { model.wrappedValue = $0 } }
        )
    }

    /// General-purpose Gemini chat/text models from Google's model
    /// list (https://aistudio.google.com/docs/models, verified
    /// 2026-11-24). Only models for the generateContent endpoint are
    /// listed: Live, TTS, image, video, embedding, music, robotics
    /// and research models use different APIs and would fail on
    /// streamGenerateContent, so they stay reachable only through
    /// the "Kustom…" row. Retired and deprecated models
    /// (gemini-2.0-flash, gemini-2.5-flash, gemini-2.5-pro) are
    /// excluded.
    struct GeminiModel: Hashable {
        let id: String
        let name: String
    }

    static let geminiModels: [GeminiModel] = [
        GeminiModel(id: "gemini-4-carbon", name: "Gemini 4 Carbon"),
        GeminiModel(id: "gemini-4-neon", name: "Gemini 4 Neon"),
        GeminiModel(id: "gemini-4-hydrogen", name: "Gemini 4 Hydrogen"),
        GeminiModel(id: "gemini-4-argon", name: "Gemini 4 Argon"),
        GeminiModel(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash"),
        GeminiModel(id: "gemini-3.6-flash", name: "Gemini 3.6 Flash"),
        GeminiModel(id: "gemini-3.5-flash-lite", name: "Gemini 3.5 Flash-Lite"),
        GeminiModel(id: "gemini-3.1-flash-lite", name: "Gemini 3.1 Flash-Lite"),
        GeminiModel(id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro"),
        GeminiModel(id: "gemini-3-flash-preview", name: "Gemini 3 Flash"),
        GeminiModel(id: "gemini-2.5-flash-lite", name: "Gemini 2.5 Flash-Lite"),
    ]

    /// Picker tag for the "type it yourself" row. Never stored as a
    /// model: when the stored model is not a catalog id, the picker
    /// shows this row and the text field stays visible.
    static let geminiCustomTag = "__kustom__"

    static func isGeminiCatalogModel(_ id: String) -> Bool {
        geminiModels.contains(where: { $0.id == id })
    }

    /// Picker selection for the Gemini model dropdown: a catalog id
    /// selects its row, anything else selects "Kustom…".
    static func geminiModelPickerBinding(model: Binding<String>) -> Binding<String> {
        Binding(
            get: { isGeminiCatalogModel(model.wrappedValue) ? model.wrappedValue : geminiCustomTag },
            set: { if $0 != geminiCustomTag { model.wrappedValue = $0 } }
        )
    }

    /// Current ChatGPT chat/reasoning models from OpenAI's model
    /// catalog (https://developers.openai.com/api/docs/models/all,
    /// verified 2026-11-24). Only models served on the Chat
    /// Completions API are listed: image, realtime/audio,
    /// moderation, embedding, cyber, restricted and open-weight
    /// models are excluded, as are deprecated/shut-down ones
    /// (gpt-4o, gpt-4o-mini, gpt-5, o3, ...). The "Kustom…" row
    /// keeps any other id reachable by typing.
    struct ChatGPTModel: Hashable {
        let id: String
        let name: String
    }

    static let chatgptModels: [ChatGPTModel] = [
        ChatGPTModel(id: "gpt-6.2-astra", name: "GPT-6.2 Astra"),
        ChatGPTModel(id: "gpt-6.2-sol", name: "GPT-6.2 Sol"),
        ChatGPTModel(id: "gpt-6.1-terra", name: "GPT-6.1 Terra"),
        ChatGPTModel(id: "gpt-6-luna", name: "GPT-6 Luna"),
        ChatGPTModel(id: "gpt-6-astra", name: "GPT-6 Astra"),
        ChatGPTModel(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"),
        ChatGPTModel(id: "gpt-6-sol", name: "GPT-6 Sol"),
        ChatGPTModel(id: "gpt-5.6-sol", name: "GPT-5.6 Sol"),
        ChatGPTModel(id: "gpt-5.6-terra", name: "GPT-5.6 Terra"),
        ChatGPTModel(id: "gpt-5.6-luna", name: "GPT-5.6 Luna"),
        ChatGPTModel(id: "gpt-5.5", name: "GPT-5.5"),
        ChatGPTModel(id: "gpt-5.5-pro", name: "GPT-5.5 Pro"),
        ChatGPTModel(id: "gpt-5.4", name: "GPT-5.4"),
        ChatGPTModel(id: "gpt-5.4-pro", name: "GPT-5.4 Pro"),
        ChatGPTModel(id: "gpt-5.4-mini", name: "GPT-5.4 Mini"),
        ChatGPTModel(id: "gpt-5.2", name: "GPT-5.2"),
        ChatGPTModel(id: "gpt-5.2-pro", name: "GPT-5.2 Pro"),
    ]

    static let chatgptCustomTag = "__kustom__"

    static func isChatGPTCatalogModel(_ id: String) -> Bool {
        chatgptModels.contains(where: { $0.id == id })
    }

    static func chatgptModelPickerBinding(model: Binding<String>) -> Binding<String> {
        Binding(
            get: { isChatGPTCatalogModel(model.wrappedValue) ? model.wrappedValue : chatgptCustomTag },
            set: { if $0 != chatgptCustomTag { model.wrappedValue = $0 } }
        )
    }

    /// Current Claude models from Anthropic's model list
    /// (https://platform.claude.com/docs/en/models/overview, verified
    /// 2026-11-24): latest, specialized and still-Active legacy
    /// models. All Claude models are text/chat models on the
    /// Messages API. Deprecated (Opus/Sonnet 4.5) and retired
    /// models (Opus/Sonnet 4, 4.1, Claude 3.x) are excluded.
    struct ClaudeModel: Hashable {
        let id: String
        let name: String
    }

    static let claudeModels: [ClaudeModel] = [
        ClaudeModel(id: "claude-opus-5-5", name: "Claude Opus 5.5"),
        ClaudeModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
        ClaudeModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5"),
        ClaudeModel(id: "claude-fable-5-2", name: "Claude Fable 5.2"),
        ClaudeModel(id: "claude-mythos-5-2", name: "Claude Mythos 5.2"),
        ClaudeModel(id: "claude-fable-5-1", name: "Claude Fable 5.1"),
        ClaudeModel(id: "claude-mythos-5-1", name: "Claude Mythos 5.1"),
        ClaudeModel(id: "claude-fable-5", name: "Claude Fable 5"),
        ClaudeModel(id: "claude-mythos-5", name: "Claude Mythos 5"),
        ClaudeModel(id: "claude-opus-5", name: "Claude Opus 5"),
        ClaudeModel(id: "claude-opus-4-8", name: "Claude Opus 4.8"),
        ClaudeModel(id: "claude-opus-4-7", name: "Claude Opus 4.7"),
        ClaudeModel(id: "claude-opus-4-6", name: "Claude Opus 4.6"),
        ClaudeModel(id: "claude-sonnet-5", name: "Claude Sonnet 5"),
        ClaudeModel(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6"),
        ClaudeModel(id: "claude-haiku-4-5", name: "Claude Haiku 4.5"),
    ]

    static let claudeCustomTag = "__kustom__"

    static func isClaudeCatalogModel(_ id: String) -> Bool {
        claudeModels.contains(where: { $0.id == id })
    }

    static func claudeModelPickerBinding(model: Binding<String>) -> Binding<String> {
        Binding(
            get: { isClaudeCatalogModel(model.wrappedValue) ? model.wrappedValue : claudeCustomTag },
            set: { if $0 != claudeCustomTag { model.wrappedValue = $0 } }
        )
    }

    /// Current OpenAI image models from the model catalog
    /// (verified 2026-11-24) for the Images API. Older image models
    /// (gpt-image-1, DALL-E) are deprecated/shut down.
    static let chatgptImageModels: [ChatGPTModel] = [
        ChatGPTModel(id: "gpt-image-2.6-sunburst", name: "GPT Image 2.6 Sunburst"),
        ChatGPTModel(id: "gpt-image-2.6-flare", name: "GPT Image 2.6 Flare"),
        ChatGPTModel(id: "gpt-image-2.5-sunburst", name: "GPT Image 2.5 Sunburst"),
        ChatGPTModel(id: "gpt-image-2.5-flare", name: "GPT Image 2.5 Flare"),
    ]

    var id: String { rawValue }
    var displayName: String { rawValue }

    var needsKey: Bool { self != .meta }

    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-3.8-flash"
        case .chatgpt: return "gpt-6-luna"
        case .claude: return "claude-haiku-4-5"
        case .balitech: return "bt/deepseek-v4.1-flash"
        case .custom: return "deepseek-v4.1-flash"
        case .meta: return ""
        }
    }

    var keyURL: String? {
        switch self {
        case .gemini: return "https://aistudio.google.com/apikey"
        case .chatgpt: return "https://platform.openai.com/api-keys"
        case .claude: return "https://console.anthropic.com/settings/keys"
        case .balitech: return "https://console.balitechsolution.com"
        case .custom: return nil
        case .meta: return nil
        }
    }

    var keyInfo: String {
        switch self {
        case .gemini: return "Gratis (ada limit harian) — ambil di Google AI Studio."
        case .chatgpt: return "Berbayar — butuh saldo di akun OpenAI."
        case .claude: return "Berbayar — butuh saldo di akun Anthropic."
        case .balitech: return "Gateway Balitechsolution (format OpenAI) — endpoint sudah diatur, isi model dan API key di bawah. Hanya request teks; gambar ditolak gateway-nya."
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

/// A single attachment held in memory for one question — never written
/// to settings. Images are downscaled and re-encoded as JPEG for
/// vision-capable models; text files are read as text into the prompt;
/// PDFs go to the model as base64 documents where the provider supports
/// them; anything else reaches the model as name, type and size only.
/// Chat sessions persist attachments up to 2 MB with their history;
/// larger ones keep only name/type/size.
struct AIAttachment: Equatable, Codable {
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

    var isZip: Bool {
        mimeType == "application/zip" || (fileName as NSString).pathExtension.lowercased() == "zip"
    }

    /// Readable text for the prompt, or nil for images, PDFs and binary
    /// files. Extension-less text and code files are covered by the
    /// UTF-8 decode + NUL check, not by the MIME type alone. ZIP
    /// files are unpacked in memory and their text/code entries are
    /// concatenated, so "jelaskan lampiran ini" on a .zip actually
    /// reaches the model as content instead of only a file name.
    var readableText: String? {
        if isImage || isPDF { return nil }
        if isZip { return zipTextContents() }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return nil }
        if text.count > 60_000 { return String(text.prefix(60_000)) + "\n... (dipotong — file lebih panjang dari ini)" }
        return text
    }

    /// Text/code entries of a ZIP, bounded like the downloaders'
    /// prompt folding: at most 100 entries, 256 KB per entry, 8.000
    /// characters total. Binary entries and entries that fail to
    /// decode are skipped; a ZIP with no readable entries yields nil
    /// and the caller falls back to the name-and-size note.
    private func zipTextContents() -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdm-zip-\(UUID().uuidString).zip")
        do {
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let archive = try Archive(url: tmp, accessMode: .read)
            var out = ""
            var count = 0
            for entry in archive {
                guard count < 100 else { break }
                guard entry.type == .file,
                      entry.uncompressedSize > 0,
                      entry.uncompressedSize <= 256_000 else { continue }
                var entryData = Data()
                do {
                    _ = try archive.extract(entry) { chunk in entryData.append(chunk) }
                } catch { continue }
                guard let text = String(data: entryData, encoding: .utf8),
                      !text.contains("\0") else { continue }
                count += 1
                out += "\n=== \(entry.path) ===\n" + text
                if out.count > 8_000 {
                    out = String(out.prefix(8_000)) + "\n... (dipotong — isi ZIP lebih panjang dari ini)"
                    break
                }
            }
            guard count > 0 else { return nil }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    static func fromPickedData(fileName: String, data: Data) -> AIAttachment {
        if let image = UIImage(data: data) {
            return AIAttachment(fileName: fileName, mimeType: "image/jpeg", data: downscaledJPEG(image), isImage: true)
        }
        let ext = (fileName as NSString).pathExtension.lowercased()
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        return AIAttachment(fileName: fileName, mimeType: mime, data: data, isImage: false)
    }

    /// Downscale + re-encode as JPEG, capped so provider gateways
    /// don't reject the request body (HTTP 413 "length limit
    /// exceeded"): a busy 1568px photo at quality 0.85 can still be
    /// ~1 MB, which base64 inflates by a third. 1024px with a
    /// quality ladder keeps the payload at or under ~500 KB while
    /// staying sharp enough for vision models.
    private static func downscaledJPEG(_ image: UIImage) -> Data {
        let maxEdge: CGFloat = 1024
        let byteCap = 500_000
        let size = image.size
        let longest = max(size.width, size.height)
        var work = image
        if longest > maxEdge {
            let scale = maxEdge / longest
            let newSize = CGSize(width: size.width * scale, height: size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            work = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        }
        var best = work.jpegData(compressionQuality: 0.8) ?? Data()
        if best.count <= byteCap { return best }
        for quality in [0.65, 0.5, 0.35] as [CGFloat] {
            let attempt = work.jpegData(compressionQuality: quality) ?? Data()
            if attempt.count < best.count { best = attempt }
            if attempt.count <= byteCap { return attempt }
        }
        return best
    }
}

/// UIKit pickers presented from the top view controller. SwiftUI's
/// `.fileImporter` silently drops selections when presented from a
/// sheet, and the Ask AI sheet is itself presented from the browser —
/// the same reason the extension import uses a UIKit presenter.
final class AIAttachmentPicker: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
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
    @discardableResult
    static func ask(provider: AIProvider, model: String, apiKey: String, endpoint: String = "",
                    attachment: AIAttachment? = nil,
                    question: String, pageTitle: String, pageURL: String, pageText: String,
                    onToken: @escaping (String) -> Void,
                    onDone: @escaping (String?) -> Void,
                    onUsage: ((AIUsage) -> Void)? = nil) -> Task<Void, Never> {
        let prompt = buildPrompt(question: question, pageTitle: pageTitle, pageURL: pageURL, pageText: pageText, attachment: attachment)
        guard let request = makeRequest(provider: provider, model: model, apiKey: apiKey, endpoint: endpoint, attachment: attachment, prompt: prompt) else {
            onDone("Tidak bisa membuat permintaan untuk \(provider.displayName).")
            return Task {}
        }
        return stream(request: request, provider: provider, onToken: onToken, onDone: onDone, onUsage: onUsage)
    }

    /// Multi-turn chat for the dedicated AI tab: the whole recent
    /// history (roles "user"/"assistant", oldest first) is sent, so the
    /// model keeps context across turns. Same streaming path as `ask`.
    /// The Ask AI sheet reuses this for follow-up questions, passing
    /// the page context as the system prompt. Returns the streaming
    /// task so the caller can stop it (the sheet's Stop button).
    /// `tools` is only honoured on the OpenAI-shape branch; other
    /// providers ignore it and chat as usual.
    @discardableResult
    static func askChat(provider: AIProvider, model: String, apiKey: String, endpoint: String = "",
                        attachment: AIAttachment? = nil,
                        messages: [(role: String, text: String)],
                        systemPrompt: String? = nil,
                        tools: [AgentTool]? = nil,
                        onToken: @escaping (String) -> Void,
                        onDone: @escaping (String?) -> Void,
                        onUsage: ((AIUsage) -> Void)? = nil) -> Task<Void, Never> {
        guard let request = makeChatRequest(provider: provider, model: model, apiKey: apiKey, endpoint: endpoint, attachment: attachment, messages: messages, systemPrompt: systemPrompt, tools: tools) else {
            onDone("Tidak bisa membuat permintaan untuk \(provider.displayName).")
            return Task {}
        }
        return stream(request: request, provider: provider, onToken: onToken, onDone: onDone, onUsage: onUsage)
    }

    /// Agent mode for the AI tab: the same multi-turn chat, but the
    /// model may call the app's own tools (files, downloads, tabs, URL
    /// fetch) and the loop feeds each tool's result back until the
    /// model answers with plain text, up to 5 rounds. Text tokens
    /// stream to onToken as they arrive, exactly like plain chat;
    /// every executed tool reports one line to onToolActivity for the
    /// bubble's tool log. OpenAI-shape providers only (ChatGPT,
    /// Custom, Balitech) — the caller gates the rest.
    /// If the first round fails while `tools` were sent (a gateway
    /// that rejects the tools field), the same turn is retried once
    /// as plain chat instead of surfacing a tools error.
    @discardableResult
    static func askChatWithTools(
        provider: AIProvider, model: String, apiKey: String, endpoint: String = "",
        attachment: AIAttachment? = nil,
        messages: [(role: String, text: String)],
        systemPrompt: String? = nil,
        tools: [AgentTool],
        store: DownloadStore,
        onToken: @escaping (String) -> Void,
        onToolActivity: @escaping (String) -> Void,
        onDone: @escaping (String?) -> Void,
        onUsage: ((AIUsage) -> Void)? = nil
    ) -> Task<Void, Never> {
        Task {
            let recent = Array(messages.suffix(20))
            let media = attachment.flatMap { $0.isImage || $0.isPDF ? $0 : nil }
            let lastText = textWithAttachmentNote(recent.last?.text ?? "", attachment: attachment, mediaAttached: media != nil)
            var apiMessages: [[String: Any]] = [["role": "system", "content": chatSystemPrompt(systemPrompt, tools: tools)]]
            apiMessages += openAIHistoryMessages(recent: recent, lastText: lastText, media: media)
            var toolsEnabled = true
            var retriedWithoutTools = false
            // Usage sums across rounds: every round is its own API
            // request, and the reference sheet counts requests.
            var totalUsage: AIUsage?
            for _ in 0..<5 {
                if Task.isCancelled { break }
                guard let request = makeOpenAIChatRequest(provider: provider, model: model, apiKey: apiKey, endpoint: endpoint, apiMessages: apiMessages, tools: toolsEnabled ? tools : nil) else {
                    await MainActor.run { onDone("Tidak bisa membuat permintaan untuk \(provider.displayName).") }
                    return
                }
                let outcome = await runChatRound(request: request, provider: provider, onToken: onToken)
                if let roundUsage = outcome.usage {
                    totalUsage = totalUsage.map { $0 + roundUsage } ?? roundUsage
                }
                if let error = outcome.error {
                    if toolsEnabled, !retriedWithoutTools {
                        toolsEnabled = false
                        retriedWithoutTools = true
                        continue
                    }
                    if let totalUsage {
                        await MainActor.run { onUsage?(totalUsage) }
                    }
                    await MainActor.run { onDone(error) }
                    return
                }
                guard !outcome.toolCalls.isEmpty else { break }
                var assistantEntry: [String: Any] = ["role": "assistant", "content": NSNull()]
                assistantEntry["tool_calls"] = outcome.toolCalls.map { call -> [String: Any] in
                    ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.argumentsJSON]]
                }
                apiMessages.append(assistantEntry)
                for call in outcome.toolCalls {
                    if Task.isCancelled { break }
                    let arguments = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
                    let result = await AgentToolRunner.run(name: call.name, arguments: arguments, store: store)
                    let line = toolActivityLine(name: call.name, result: result)
                    await MainActor.run { onToolActivity(line) }
                    apiMessages.append(["role": "tool", "tool_call_id": call.id, "content": result])
                }
            }
            if let totalUsage {
                await MainActor.run { onUsage?(totalUsage) }
            }
            await MainActor.run { onDone(nil) }
        }
    }

    /// Image generation for the ChatGPT provider only: the OpenAI
    /// Images API. Other providers cannot generate images from this
    /// app, and the Balitech gateway rejects image content outright.
    static func generateImage(prompt: String, model: String, size: String, apiKey: String,
                              onDone: @escaping (Data?, String?) -> Void) -> Task<Void, Never> {
        Task {
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            let body: [String: Any] = ["model": model, "prompt": prompt, "size": size, "n": 1, "response_format": "b64_json"]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    await MainActor.run { onDone(nil, "Respons tidak dikenal dari OpenAI.") }
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    let snippet = String((String(data: data, encoding: .utf8) ?? "").prefix(300))
                    await MainActor.run { onDone(nil, "Error HTTP \(http.statusCode) dari OpenAI: \(snippet)") }
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = json["data"] as? [[String: Any]],
                      let first = items.first,
                      let b64 = first["b64_json"] as? String,
                      let imageData = Data(base64Encoded: b64) else {
                    await MainActor.run { onDone(nil, "OpenAI tidak mengembalikan gambar.") }
                    return
                }
                await MainActor.run { onDone(imageData, nil) }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { onDone(nil, error.localizedDescription) }
            }
        }
    }

    /// One streamed tool-call delta fragment, accumulated by index:
    /// the first fragment carries the id and name, later ones only
    /// append to the arguments JSON string.
    private struct PendingToolCall {
        var id: String = ""
        var name: String = ""
        var argumentsJSON: String = ""
    }

    /// A single streamed chat/completions round: text tokens stream to
    /// onToken as they arrive, and any tool calls the model emitted
    /// are returned for execution. Mirrors `stream`'s error handling
    /// (413 message, HTTP snippet) so agent mode fails the same way
    /// plain chat does. Cancellation ends the round quietly.
    private static func runChatRound(request: URLRequest, provider: AIProvider,
                                     onToken: @escaping (String) -> Void) async -> (toolCalls: [PendingToolCall], error: String?, usage: AIUsage?) {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ([], "Respons tidak dikenal dari \(provider.displayName).", nil)
            }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 413 {
                    return ([], "Lampiran terlalu besar untuk server \(provider.displayName) (HTTP 413 — badan request melebihi batas gateway). Coba kirim foto/file yang lebih kecil.", nil)
                }
                var body = ""
                for try await line in bytes.lines { body += line + "\n" }
                let snippet = String(body.prefix(300))
                return ([], "Error HTTP \(http.statusCode) dari \(provider.displayName): \(snippet)", nil)
            }
            var calls: [Int: PendingToolCall] = [:]
            var runningUsage = AIUsage()
            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("data:") else { continue }
                let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let chunkUsage = AIUsage.chunkUsage(provider: provider, json: json) {
                    runningUsage.absorb(chunkUsage)
                }
                if let deltaText = extractDelta(provider: provider, json: json), !deltaText.isEmpty {
                    let token = deltaText
                    await MainActor.run { onToken(token) }
                }
                if let fragments = toolCallFragments(json: json) {
                    for (index, id, name, arguments) in fragments {
                        var call = calls[index] ?? PendingToolCall()
                        if !id.isEmpty { call.id = id }
                        if !name.isEmpty { call.name = name }
                        call.argumentsJSON += arguments
                        calls[index] = call
                    }
                }
            }
            let ordered = calls.keys.sorted().compactMap { index -> PendingToolCall? in
                guard var call = calls[index], !call.name.isEmpty else { return nil }
                if call.id.isEmpty { call.id = "call_\(index)" }
                return call
            }
            return (ordered, nil, runningUsage.hasData ? runningUsage : nil)
        } catch {
            if Task.isCancelled { return ([], nil, nil) }
            return ([], error.localizedDescription, nil)
        }
    }

    /// Tool-call fragments from one OpenAI-shape SSE delta:
    /// choices[0].delta.tool_calls[i] = {index, id, function:{name,
    /// arguments}}. Anything else returns nil.
    private static func toolCallFragments(json: [String: Any]) -> [(index: Int, id: String, name: String, arguments: String)]? {
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let rawCalls = delta["tool_calls"] as? [[String: Any]] else { return nil }
        return rawCalls.compactMap { raw in
            guard let index = raw["index"] as? Int else { return nil }
            let id = raw["id"] as? String ?? ""
            let function = raw["function"] as? [String: Any] ?? [:]
            return (index, id, function["name"] as? String ?? "", function["arguments"] as? String ?? "")
        }
    }

    /// One line for the chat's tool log: the tool name plus the first
    /// line of its result, so a file listing does not flood the bubble.
    private static func toolActivityLine(name: String, result: String) -> String {
        let first = result.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let single = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return String("\(name): \(single)".prefix(160))
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

    /// The system prompt for multi-turn chat. `systemPrompt`
    /// overrides the generic any-topic prompt (the Ask AI sheet passes
    /// the page context); agent mode appends the tools instruction.
    private static func chatSystemPrompt(_ systemPrompt: String?, tools: [AgentTool]? = nil) -> String {
        var prompt = systemPrompt ?? "Kamu adalah asisten AI serba bisa. Jawablah pertanyaan apa pun tentang topik apa pun, tanpa batasan topik — tidak terbatas pada aplikasi ini. Jawablah dalam bahasa yang sama dengan pesan pengguna, ringkas tapi lengkap."
        if tools != nil {
            prompt += "\n\nKamu dapat memakai perkakas (tools) yang disediakan untuk memeriksa keadaan aplikasi ini — file, download, tab browser, isi URL, inspeksi halaman (JavaScript, DOM, console, network, cookie, storage, info halaman), dan request API yang tersimpan di API Tester, yang bisa kamu baca dan kirim — sebelum menjawab. Pakailah perkakas saat pertanyaan membutuhkan data nyata dari aplikasi, jangan menebak. Sebutkan dengan singkat perkakas apa yang kamu pakai dan apa hasilnya."
            prompt += "\n\nJika pesan pengguna membawa lampiran (file atau foto), isi lampiran sudah disertakan di dalam pesan itu sendiri — jawablah dari isi tersebut, dan jangan memakai perkakas untuk mencari file lampiran itu di dalam aplikasi."
        }
        return prompt
    }

    /// History messages in the OpenAI chat/completions shape. The
    /// newest message carries the attachment as a media part when it
    /// is an image or PDF; older attachments ride as name notes (the
    /// caller folds those into the history text).
    private static func openAIHistoryMessages(recent: [(role: String, text: String)], lastText: String, media: AIAttachment?) -> [[String: Any]] {
        let lastIndex = max(0, recent.count - 1)
        return recent.enumerated().map { idx, msg -> [String: Any] in
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
    }

    /// POSTs to an OpenAI chat/completions URL (OpenAI itself, a
    /// Custom base URL, or the fixed Balitech gateway), with an
    /// optional `tools` array for agent mode.
    private static func makeOpenAIChatRequest(provider: AIProvider, model: String, apiKey: String, endpoint: String, apiMessages: [[String: Any]], tools: [AgentTool]? = nil) -> URLRequest? {
        let urlString: String
        if provider == .custom {
            guard let url = chatCompletionsURL(baseURL: endpoint) else { return nil }
            urlString = url.absoluteString
        } else if provider == .balitech {
            guard let url = chatCompletionsURL(baseURL: AIProvider.balitechBaseURL) else { return nil }
            urlString = url.absoluteString
        } else {
            urlString = "https://api.openai.com/v1/chat/completions"
        }
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "stream": true, "messages": apiMessages,
                                    // Ask for the final chunk's `usage` object: without
                                    // this, streamed OpenAI-shape responses carry no
                                    // token counts at all.
                                    "stream_options": ["include_usage": true]]
        if let tools, !tools.isEmpty {
            body["tools"] = tools.map(\.schema)
            body["tool_choice"] = "auto"
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func makeChatRequest(provider: AIProvider, model: String, apiKey: String, endpoint: String, attachment: AIAttachment?, messages: [(role: String, text: String)], systemPrompt: String? = nil, tools: [AgentTool]? = nil) -> URLRequest? {
        let system = chatSystemPrompt(systemPrompt, tools: tools)
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
        case .chatgpt, .custom, .balitech:
            // Same OpenAI chat/completions shape as makeRequest; Custom
            // points it at the user's own base URL, Balitech at the
            // fixed Balitechsolution gateway.
            let apiMessages: [[String: Any]] = [["role": "system", "content": system]]
                + openAIHistoryMessages(recent: recent, lastText: lastText, media: media)
            return makeOpenAIChatRequest(provider: provider, model: model, apiKey: apiKey, endpoint: endpoint, apiMessages: apiMessages, tools: tools)
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
        case .chatgpt, .custom, .balitech:
            // Same OpenAI chat/completions shape; Custom just points it
            // at the user's own base URL instead of api.openai.com,
            // Balitech at the fixed Balitechsolution gateway.
            let urlString: String
            if provider == .custom {
                guard let url = chatCompletionsURL(baseURL: endpoint) else { return nil }
                urlString = url.absoluteString
            } else if provider == .balitech {
                guard let url = chatCompletionsURL(baseURL: AIProvider.balitechBaseURL) else { return nil }
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
                "stream_options": ["include_usage": true],
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

    @discardableResult
    private static func stream(request: URLRequest, provider: AIProvider,
                               onToken: @escaping (String) -> Void,
                               onDone: @escaping (String?) -> Void,
                               onUsage: ((AIUsage) -> Void)? = nil) -> Task<Void, Never> {
        Task {
            // Token usage accumulates from the usage chunks (the final
            // chunk for OpenAI/Gemini, start+delta events for Claude)
            // and is delivered just before onDone, even for a stopped
            // stream, so a partial answer keeps its numbers.
            var runningUsage = AIUsage()
            func finish(_ error: String?) {
                // One MainActor hop delivers usage before onDone, in
                // order, so the caller can stamp the duration onto the
                // usage in onDone.
                let usage = runningUsage.hasData ? runningUsage : nil
                Task { @MainActor in
                    if let usage { onUsage?(usage) }
                    onDone(error)
                }
            }
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    await MainActor.run { onDone("Respons tidak dikenal dari \(provider.displayName).") }
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    if http.statusCode == 413 {
                        await MainActor.run { onDone("Lampiran terlalu besar untuk server \(provider.displayName) (HTTP 413 — badan request melebihi batas gateway). Coba kirim foto/file yang lebih kecil.") }
                        return
                    }
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
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let chunkUsage = AIUsage.chunkUsage(provider: provider, json: json) {
                        runningUsage.absorb(chunkUsage)
                    }
                    guard let text = extractDelta(provider: provider, json: json),
                          !text.isEmpty else { continue }
                    let token = text
                    await MainActor.run { onToken(token) }
                }
                finish(nil)
            } catch {
                // A cancelled stream (the sheet's Stop button) ends
                // quietly with whatever arrived so far — it is not an
                // error, and the caller must not show a failure for it.
                if Task.isCancelled {
                    finish(nil)
                } else {
                    let message = error.localizedDescription
                    await MainActor.run { onDone(message) }
                }
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
        case .chatgpt, .custom, .balitech:
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

/// One question + streamed answer in the Ask AI sheet. Follow-up
/// questions append turns, so the sheet is a short conversation
/// instead of a single shot.
private struct AskTurn: Identifiable, Equatable {
    let id = UUID()
    var question: String
    var answer: String
    var attachment: AIAttachment?
    var error: String?
    /// Token usage the provider reported for this answer, if any.
    var usage: AIUsage?
    /// The model id that produced this answer, for the usage sheet.
    var modelName: String = ""

    init(question: String, answer: String = "", attachment: AIAttachment? = nil, error: String? = nil, usage: AIUsage? = nil, modelName: String = "") {
        self.question = question
        self.answer = answer
        self.attachment = attachment
        self.error = error
        self.usage = usage
        self.modelName = modelName
    }
}

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
    @State private var turns: [AskTurn] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var copiedNotice = false
    @State private var includePageContext = true
    @State private var showConfig = false
    @State private var stopped = false
    @State private var requestTask: Task<Void, Never>?
    @State private var copiedTurnID: UUID?
    @State private var viewerImage: ViewableImage?
    @State private var usageTurn: AskTurn?
    @StateObject private var transcriber = SpeechTranscriber()
    @State private var dictationBase = ""
    @State private var composerActionsExpanded = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Tapping outside the field hides the keyboard.
                    // Scoped to the non-editable sections: a blanket
                    // gesture would also fire when tapping the config
                    // text fields and unfocus them instantly.
                    // simultaneousGesture (like the AI tab) keeps
                    // double-tap text selection working.
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

                        Toggle("Sertakan konteks halaman ini", isOn: $includePageContext)
                            .font(.subheadline)
                            .disabled(isLoading)
                    }
                    .simultaneousGesture(TapGesture().onEnded { fieldFocused = false })

                    DisclosureGroup(isExpanded: $showConfig) {
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
                                    .focused($fieldFocused)
                                    .autocapitalization(.none).autocorrectionDisabled()
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                                Text("URL dasar endpoint-nya — boleh juga ditempel lengkap sampai /chat/completions. Permintaan dikirim persis seperti contoh curl: POST, header Authorization Bearer, body model + messages.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Model").font(.headline)
                            if provider == .balitech {
                                Picker("Model", selection: AIProvider.modelPickerBinding(model: $model, known: AIProvider.knownModelIDs(for: .balitech, settings: store.browserSettings))) {
                                    ForEach(AIProvider.balitechModels, id: \.id) { m in
                                        Text(m.name).tag(m.id)
                                    }
                                    ForEach((store.browserSettings.aiDiscoveredModels[AIProvider.balitech.rawValue] ?? []).filter { !AIProvider.isBalitechCatalogModel($0) }, id: \.self) { id in
                                        Text(id).tag(id)
                                    }
                                    ForEach(store.browserSettings.aiCustomModels[AIProvider.balitech.rawValue] ?? [], id: \.self) { id in
                                        Text(id).tag(id)
                                    }
                                    Text("Kustom…").tag(AIProvider.modelCustomTag)
                                }
                                .pickerStyle(.menu)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                                if !AIProvider.knownModelIDs(for: .balitech, settings: store.browserSettings).contains(model) {
                                    TextField("Model", text: $model)
                                        .focused($fieldFocused)
                                        .autocapitalization(.none).autocorrectionDisabled()
                                        .padding(.horizontal, 12).padding(.vertical, 10)
                                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                                }
                                Text(model).font(.caption).foregroundStyle(.secondary)
                            } else if provider == .gemini {
                                Picker("Model", selection: AIProvider.modelPickerBinding(model: $model, known: AIProvider.knownModelIDs(for: .gemini, settings: store.browserSettings))) {
                                    ForEach(AIProvider.geminiModels, id: \.id) { m in
                                        Text(m.name).tag(m.id)
                                    }
                                    ForEach((store.browserSettings.aiDiscoveredModels[AIProvider.gemini.rawValue] ?? []).filter { !AIProvider.isGeminiCatalogModel($0) }, id: \.self) { id in
                                        Text(id).tag(id)
                                    }
                                    ForEach(store.browserSettings.aiCustomModels[AIProvider.gemini.rawValue] ?? [], id: \.self) { id in
                                        Text(id).tag(id)
                                    }
                                    Text("Kustom…").tag(AIProvider.modelCustomTag)
                                }
                                .pickerStyle(.menu)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                                if !AIProvider.knownModelIDs(for: .gemini, settings: store.browserSettings).contains(model) {
                                    TextField("Model", text: $model)
                                        .focused($fieldFocused)
                                        .autocapitalization(.none).autocorrectionDisabled()
                                        .padding(.horizontal, 12).padding(.vertical, 10)
                                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                                }
                                Text(model).font(.caption).foregroundStyle(.secondary)
                            } else if provider == .chatgpt {
                                Picker("Model", selection: AIProvider.modelPickerBinding(model: $model, known: AIProvider.knownModelIDs(for: .chatgpt, settings: store.browserSettings))) {
                                    ForEach(AIProvider.chatgptModels, id: \.id) { m in
                                        Text(m.name).tag(m.id)
                                    }
                                    ForEach((store.browserSettings.aiDiscoveredModels[AIProvider.chatgpt.rawValue] ?? []).filter { !AIProvider.isChatGPTCatalogModel($0) }, id: \.self) { id in
                                        Text(id).tag(id)
                                    }
                                    ForEach(store.browserSettings.aiCustomModels[AIProvider.chatgpt.rawValue] ?? [], id: \.self) { id in
                                        Text(id).tag(id)
                                    }
                                    Text("Kustom…").tag(AIProvider.modelCustomTag)
                                }
                                .pickerStyle(.menu)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                                if !AIProvider.knownModelIDs(for: .chatgpt, settings: store.browserSettings).contains(model) {
                                    TextField("Model", text: $model)
                                        .focused($fieldFocused)
                                        .autocapitalization(.none).autocorrectionDisabled()
                                        .padding(.horizontal, 12).padding(.vertical, 10)
                                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                                }
                                Text(model).font(.caption).foregroundStyle(.secondary)
                            } else if provider == .claude {
                                Picker("Model", selection: AIProvider.modelPickerBinding(model: $model, known: AIProvider.knownModelIDs(for: .claude, settings: store.browserSettings))) {
                                    ForEach(AIProvider.claudeModels, id: \.id) { m in
                                        Text(m.name).tag(m.id)
                                    }
                                    ForEach((store.browserSettings.aiDiscoveredModels[AIProvider.claude.rawValue] ?? []).filter { !AIProvider.isClaudeCatalogModel($0) }, id: \.self) { id in
                                        Text(id).tag(id)
                                    }
                                    ForEach(store.browserSettings.aiCustomModels[AIProvider.claude.rawValue] ?? [], id: \.self) { id in
                                        Text(id).tag(id)
                                    }
                                    Text("Kustom…").tag(AIProvider.modelCustomTag)
                                }
                                .pickerStyle(.menu)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                                if !AIProvider.knownModelIDs(for: .claude, settings: store.browserSettings).contains(model) {
                                    TextField("Model", text: $model)
                                        .focused($fieldFocused)
                                        .autocapitalization(.none).autocorrectionDisabled()
                                        .padding(.horizontal, 12).padding(.vertical, 10)
                                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                                }
                                Text(model).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Picker("Model", selection: AIProvider.modelPickerBinding(model: $model, known: AIProvider.knownModelIDs(for: .custom, settings: store.browserSettings))) {
                                    ForEach(store.browserSettings.aiDiscoveredModels[AIProvider.custom.rawValue] ?? [], id: \.self) { id in
                                        Text(id).tag(id)
                                    }
                                    ForEach(store.browserSettings.aiCustomModels[AIProvider.custom.rawValue] ?? [], id: \.self) { id in
                                        Text(id).tag(id)
                                    }
                                    Text("Kustom…").tag(AIProvider.modelCustomTag)
                                }
                                .pickerStyle(.menu)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                                if !AIProvider.knownModelIDs(for: .custom, settings: store.browserSettings).contains(model) {
                                    TextField("Model", text: $model)
                                        .focused($fieldFocused)
                                        .autocapitalization(.none).autocorrectionDisabled()
                                        .padding(.horizontal, 12).padding(.vertical, 10)
                                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                                }
                                Text(model).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("API key").font(.headline)
                            SecureField("API key \(provider.displayName)", text: $apiKey)
                                .focused($fieldFocused)
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
                    } label: {
                        HStack {
                            Text("Pengaturan AI").font(.subheadline)
                            Spacer()
                            Text(configSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(turns) { turn in
                            turnView(turn)
                        }

                        if turns.isEmpty, !isLoading {
                            HStack(spacing: 8) {
                                quickAction("Ringkas halaman ini")
                                quickAction("Jelaskan sederhana")
                            }
                            HStack(spacing: 8) {
                                quickAction("Apa isi halaman ini?")
                            }
                        }

                        if let last = turns.last, !last.answer.isEmpty, !isLoading {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Pertanyaan lanjutan").font(.subheadline).foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    quickAction("Jelaskan lebih sederhana")
                                    quickAction("Beri contoh")
                                }
                                HStack(spacing: 8) {
                                    quickAction("Apa lagi yang penting dari halaman ini?")
                                }
                            }
                        }

                        if !turns.isEmpty, !isLoading {
                            Button { handOffToAITab() } label: {
                                Label("Lanjut di tab AI", systemImage: "sparkles")
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .font(.subheadline)
                        }

                        if let errorText {
                            Text(errorText).font(.subheadline).foregroundStyle(.red)
                        }
                    }
                    .simultaneousGesture(TapGesture().onEnded { fieldFocused = false })
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            }
            Divider()
            composer
            }
            .navigationTitle("Minta AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Selesai") { dismiss() } }
            }
        }
        .onAppear {
            provider = AIProvider(rawValue: store.browserSettings.aiProvider) ?? .gemini
            loadModelAndKey()
            showConfig = !keySaved
        }
        .onDisappear {
            fieldFocused = false
            requestTask?.cancel()
            requestTask = nil
            transcriber.stop()
        }
        .onChange(of: transcriber.liveText) { text in
            guard transcriber.isRecording else { return }
            question = dictationBase + (dictationBase.isEmpty || text.isEmpty ? "" : " ") + text
        }
        .onChange(of: transcriber.errorMessage) { message in
            // Dictation failures used to be silent — the mic just
            // looked dead. Surface the reason in the error banner.
            if let message { errorText = message }
        }
        .onChange(of: transcriber.isRecording) { recording in
            if !recording { dictationBase = question } else { errorText = nil }
        }
        .onChange(of: provider) { newValue in
            requestTask?.cancel()
            requestTask = nil
            turns = []
            store.browserSettings.aiProvider = newValue.rawValue
            store.saveBrowserSettings()
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
        // The catalog slug carries the bt/ prefix; an older stored
        // bare name for the same model is normalized to it once.
        if provider == .balitech, model == "deepseek-v4.1-flash" {
            model = "bt/deepseek-v4.1-flash"
        }
        // Google retired gemini-2.0-flash (HTTP 404); its own error
        // message names gemini-3.8-flash as the replacement.
        if provider == .gemini, model == "gemini-2.0-flash" {
            model = "gemini-3.8-flash"
        }
        // OpenAI deprecated gpt-4o-mini (shutdown 14 Jan 2027) and
        // names gpt-6-luna as its replacement.
        if provider == .chatgpt, model == "gpt-4o-mini" {
            model = "gpt-6-luna"
        }
        // Anthropic retired claude-3-5-haiku-20241022; the named
        // replacement is Haiku 4.5 (stored here by its alias).
        if provider == .claude, model == "claude-3-5-haiku-20241022" {
            model = "claude-haiku-4-5"
        }
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
        transcriber.stop()
        composerActionsExpanded = false
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let att = attachment
        guard !isLoading else { return }
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
        guard !q.isEmpty || att != nil else { return }
        // Sending with only an attachment asks about it, like the AI tab.
        let questionText = q.isEmpty ? "Jelaskan lampiran ini." : q
        question = ""
        attachment = nil
        errorText = nil
        turns.append(AskTurn(question: questionText, attachment: att))
        streamTurn(index: turns.count - 1)
    }

    /// Streams the answer for one turn, sending the earlier turns as
    /// history so follow-ups keep context. The page context rides as
    /// the system prompt when the toggle is on.
    private func streamTurn(index: Int) {
        guard turns.indices.contains(index) else { return }
        let turn = turns[index]
        isLoading = true
        stopped = false
        var history: [(role: String, text: String)] = []
        for prior in turns[..<index] {
            history.append((role: "user", text: historyText(for: prior)))
            if !prior.answer.isEmpty {
                history.append((role: "assistant", text: prior.answer))
            }
        }
        history.append((role: "user", text: turn.question))
        let startedAt = Date()
        let sentModel = model
        requestTask = AIClient.askChat(
            provider: provider, model: model, apiKey: apiKey, endpoint: endpoint,
            attachment: turn.attachment, messages: history,
            systemPrompt: includePageContext ? pageSystemPrompt : nil,
            onToken: { token in
                guard !stopped, turns.indices.contains(index) else { return }
                turns[index].answer += token
            },
            onDone: { message in
                isLoading = false
                requestTask = nil
                guard !stopped, turns.indices.contains(index) else { return }
                if var usage = turns[index].usage {
                    usage.durationSeconds = Date().timeIntervalSince(startedAt)
                    turns[index].usage = usage
                    turns[index].modelName = sentModel
                }
                if let message {
                    turns[index].error = message
                } else if turns[index].answer.isEmpty {
                    turns[index].error = "Tidak ada jawaban dari \(provider.displayName). Coba cek model dan kunci API-nya."
                }
            },
            onUsage: { usage in
                guard turns.indices.contains(index) else { return }
                turns[index].usage = usage
                turns[index].modelName = sentModel
            }
        )
    }

    /// Re-asks one turn, dropping the turns after it (they answered a
    /// different question) — the same rule as retry in the AI tab.
    private func regenerate(_ turn: AskTurn) {
        guard !isLoading, let idx = turns.firstIndex(where: { $0.id == turn.id }) else { return }
        turns = Array(turns[...idx])
        turns[idx].answer = ""
        turns[idx].error = nil
        streamTurn(index: idx)
    }

    private func stopStreaming() {
        stopped = true
        requestTask?.cancel()
        requestTask = nil
        isLoading = false
    }

    /// A past turn's question as history text: readable file
    /// attachments are inlined, images/PDFs keep a name note — the
    /// same rule the AI tab uses for older messages.
    private func historyText(for turn: AskTurn) -> String {
        guard let att = turn.attachment else { return turn.question }
        if let readable = att.readableText {
            return turn.question + "\n\nLampiran file \(att.fileName):\n\(readable)"
        }
        return turn.question + " [Lampiran: \(att.fileName)]"
    }

    /// The page context as a system prompt: same wording as the old
    /// single-shot prompt, minus the question and attachment parts,
    /// which the chat request carries on the messages themselves.
    private var pageSystemPrompt: String {
        var parts: [String] = []
        parts.append("Kamu adalah asisten AI di dalam browser. Jawablah dalam bahasa yang sama dengan pertanyaan pengguna.")
        parts.append("Halaman yang sedang dibuka:\nJudul: \(pageTitle)\nURL: \(pageURL)")
        let trimmed = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            parts.append("Isi halaman: (tidak ada teks yang bisa dibaca dari halaman ini)")
        } else {
            parts.append("Isi halaman (dipotong):\n\(pageText)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Hands the whole sheet conversation to the AI tab as a saved
    /// session: the tab picks it up through the store mailbox and
    /// switches over, so the chat survives in projects like any other.
    private func handOffToAITab() {
        guard !turns.isEmpty else { return }
        var messages: [AIChatMessage] = []
        for turn in turns {
            messages.append(AIChatMessage(role: "user", text: turn.question, attachment: turn.attachment))
            if !turn.answer.isEmpty {
                messages.append(AIChatMessage(role: "assistant", text: turn.answer))
            }
        }
        let first = turns.first?.question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ") ?? ""
        store.aiHandoff = AIChatHandoff(
            title: first.isEmpty ? "Tanya AI" : String(first.prefix(40)),
            messages: messages
        )
        dismiss()
    }

    private func copyAnswer(_ turn: AskTurn) {
        UIPasteboard.general.string = turn.answer
        copiedTurnID = turn.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedTurnID == turn.id { copiedTurnID = nil }
        }
    }

    private func shareAnswer(_ turn: AskTurn) {
        shareTextFromTop(turn.answer)
    }

    private func shareTextFromTop(_ text: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) else { return }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
        }
        top?.present(activity, animated: true)
    }

    private var configSummary: String {
        if provider == .meta { return "Muse · lewat web" }
        let m = model.isEmpty ? provider.defaultModel : model
        return "\(provider.displayName) · \(m) · \(keySaved ? "kunci tersimpan" : "kunci belum diisi")"
    }

    private var canAsk: Bool {
        let textPresent = !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isLoading && provider != .meta && (textPresent || attachment != nil)
            && !(provider.needsKey && apiKey.isEmpty) && !missingEndpoint
    }

    private func turnView(_ turn: AskTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    if let att = turn.attachment {
                        attachmentChip(att)
                    }
                    Text(turn.question)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            if !turn.answer.isEmpty || (isLoading && turn.id == turns.last?.id) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Jawaban").font(.headline)
                        Spacer()
                        Button { copyAnswer(turn) } label: {
                            Label(copiedTurnID == turn.id ? "Disalin" : "Salin", systemImage: "doc.on.doc")
                        }
                        .font(.subheadline)
                        Button { shareAnswer(turn) } label: {
                            Label("Bagikan", systemImage: "square.and.arrow.up")
                        }
                        .font(.subheadline)
                    }
                    if turn.answer.isEmpty {
                        HStack { ProgressView(); Text("Meminta jawaban…").foregroundStyle(.secondary) }
                            .font(.subheadline)
                    } else {
                        MarkdownChatView(text: turn.answer)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            if let usage = turn.usage, usage.hasData, !turn.answer.isEmpty {
                Button { usageTurn = turn } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.fill")
                        Text(usage.caption)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = turn.error {
                HStack(spacing: 6) {
                    Text(error).font(.subheadline).foregroundStyle(.red)
                    Spacer()
                    Button("Coba lagi") { regenerate(turn) }
                        .font(.subheadline)
                        .disabled(isLoading)
                }
            } else if turn.id == turns.last?.id, !turn.answer.isEmpty, !isLoading {
                HStack {
                    Spacer()
                    Button { regenerate(turn) } label: {
                        Label("Minta jawaban ulang", systemImage: "arrow.clockwise")
                    }
                    .font(.subheadline)
                }
            }
        }
        .sheet(item: $usageTurn) { turn in
            if let usage = turn.usage {
                MessageUsageView(modelName: turn.modelName, usage: usage)
            }
        }
    }

    private func attachmentChip(_ att: AIAttachment) -> some View {
        HStack(spacing: 6) {
            if att.isImage, let uiImage = UIImage(data: att.data) {
                Image(uiImage: uiImage).resizable().scaledToFill()
                    .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "doc.fill").foregroundStyle(.secondary)
            }
            Text(att.fileName).lineLimit(1)
            Text(att.displaySize).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(.tertiarySystemBackground), in: Capsule())
        .onTapGesture {
            if att.isImage, let uiImage = UIImage(data: att.data) {
                viewerImage = ViewableImage(image: uiImage, fileName: att.fileName)
            }
        }
        .fullScreenCover(item: $viewerImage) { ChatImageViewer(viewable: $0) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let att = attachment {
                HStack(spacing: 10) {
                    if att.isImage, let uiImage = UIImage(data: att.data) {
                        Image(uiImage: uiImage)
                            .resizable().scaledToFill()
                            .frame(width: 44, height: 44).clipped().cornerRadius(8)
                    } else {
                        Image(systemName: att.isPDF ? "doc.fill" : "doc")
                            .font(.title2).foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(att.fileName).font(.subheadline).lineLimit(2)
                        Text("\(att.displaySize) · \(att.isImage ? "foto" : att.isPDF ? "PDF" : att.mimeType)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { attachment = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
            // iOS 26 Messages-style composer, same as the AI tab: one
            // glass capsule with a "+" menu, the field, and a trailing
            // button that swaps between mic and send.
            VStack(alignment: .leading, spacing: 8) {
                if composerActionsExpanded {
                    HStack(spacing: 20) {
                        sheetComposerActionButton(icon: "photo", label: "Foto") {
                            composerActionsExpanded = false
                            pickPhoto()
                        }
                        sheetComposerActionButton(icon: "folder", label: "File") {
                            composerActionsExpanded = false
                            pickFile()
                        }
                    }
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                HStack(spacing: 4) {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            composerActionsExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(Color(.tertiarySystemFill), in: Circle())
                            .rotationEffect(.degrees(composerActionsExpanded ? 45 : 0))
                    }
                    .disabled(isLoading || provider == .meta)
                    // Same field as the AI tab: a vertical-axis
                    // TextField capped at 5 lines. The previous
                    // TextEditor grew unbounded in this sheet and
                    // blew the capsule up to half the sheet.
                    TextField("Tulis pertanyaan…", text: $question, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($fieldFocused)
                        .padding(.vertical, 8)
                    if isLoading {
                        Button { stopStreaming() } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.red)
                        }
                        .frame(width: 34, height: 34)
                    } else if canAsk {
                        Button { send() } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 30))
                        }
                    } else {
                        Button {
                            if transcriber.isRecording {
                                transcriber.stop()
                            } else {
                                dictationBase = question
                                transcriber.toggle()
                            }
                        } label: {
                            Image(systemName: transcriber.isRecording ? "mic.fill" : "mic")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(transcriber.isRecording ? .red : .primary)
                                .frame(width: 32, height: 32)
                                .background(Color(.tertiarySystemFill), in: Circle())
                        }
                        .disabled(provider == .meta)
                    }
                }
                // Hug the content height: the capsule must never
                // stretch to fill the sheet.
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            }
            if turns.isEmpty {
                Text("Satu lampiran per pertanyaan; pilih lagi untuk mengganti. Foto dikirim sebagai gambar, file teks dibaca isinya, PDF dikirim sebagai dokumen — semua tergantung model dan endpoint-nya mendukung atau tidak. Jenis file lain hanya terbaca nama dan ukurannya.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// One action in the sheet composer's expandable "+" strip: a
    /// glass circle with a caption, like the iOS 26 Messages app strip.
    private func sheetComposerActionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(isLoading || provider == .meta)
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
