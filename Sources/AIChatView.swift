import SwiftUI

// MARK: - AI chat tab
//
// A dedicated chat column next to the Browser tab. It talks to the same
// providers as the Ask AI sheet, but keeps a multi-turn history, and its
// own provider choice defaults to Custom — any OpenAI-compatible
// chat/completions endpoint (the format from the user's own gateway),
// configured with a base URL, a model name and an API key. History is
// in-memory only: closing the app starts a fresh chat.

private struct AIChatMessage: Identifiable, Equatable {
    let id: UUID
    var role: String // "user" or "assistant"
    var text: String
    var attachment: AIAttachment?

    // Explicit init: the synthesized memberwise init does not expose
    // `id` (it has a default value), and the streaming path needs to
    // construct a message with a known id to append tokens to.
    init(id: UUID = UUID(), role: String, text: String, attachment: AIAttachment? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.attachment = attachment
    }
}

struct AIChatView: View {
    @EnvironmentObject var store: DownloadStore
    @State private var provider: AIProvider = .custom
    @State private var model = ""
    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var messages: [AIChatMessage] = []
    @State private var streamingID: UUID?
    @State private var draft = ""
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var showingSettings = false
    @State private var attachment: AIAttachment?
    @State private var attachmentPicker = AIAttachmentPicker()
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if messages.isEmpty {
                                emptyState
                            } else {
                                ForEach(messages) { message in
                                    bubble(message)
                                }
                            }
                            if isLoading, messages.first(where: { $0.id == streamingID }) == nil {
                                HStack { ProgressView(); Text("Menjawab…").foregroundStyle(.secondary) }
                                    .font(.subheadline)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: messages) { _ in
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                if let errorText {
                    Text(errorText)
                        .font(.subheadline).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground))
                }
                if let att = attachment {
                    HStack(spacing: 8) {
                        if att.isImage, let uiImage = UIImage(data: att.data) {
                            Image(uiImage: uiImage).resizable().scaledToFill()
                                .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: "doc.fill").font(.title3).foregroundStyle(.secondary)
                                .frame(width: 40, height: 40)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(att.fileName).font(.subheadline).lineLimit(1)
                            Text(att.displaySize).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { attachment = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 8)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Button { pickPhoto() } label: { Image(systemName: "photo") }
                        .font(.system(size: 20))
                        .frame(width: 38, height: 38)
                        .disabled(isLoading)
                    Button { pickFile() } label: { Image(systemName: "folder") }
                        .font(.system(size: 20))
                        .frame(width: 38, height: 38)
                        .disabled(isLoading)
                    TextField("Tulis pesan…", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($inputFocused)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                        .onSubmit { send() }
                    if isLoading {
                        ProgressView()
                            .frame(width: 38, height: 38)
                    } else {
                        Button { send() } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                        }
                        .disabled(!canSend)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            // Fixed 12pt: the TabView's safeAreaInset already parks the
            // column's bottom edge above the pill, so the field only
            // needs a small gap — the old 72pt (from the discarded
            // bar-height measurement) floated it far above the bar.
            .padding(.bottom, 12)
            .navigationTitle("AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { messages = []; errorText = nil } label: {
                        Label("Chat baru", systemImage: "square.and.pencil")
                    }
                    .disabled(messages.isEmpty || isLoading)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingSettings = true } label: {
                        Label("Pengaturan AI", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                AIChatSettingsView(provider: $provider, model: $model, endpoint: $endpoint, apiKey: $apiKey, keySaved: $keySaved)
            }
        }
        .onAppear {
            provider = AIProvider(rawValue: store.browserSettings.aiChatProvider) ?? .custom
            if provider == .meta { provider = .custom }
            loadModelAndKey()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.blue)
            Text("Tanya apa saja").font(.headline)
            Text("\(provider.displayName) · \(model.isEmpty ? provider.defaultModel : model)")
                .font(.subheadline).foregroundStyle(.secondary)
            if provider == .custom {
                Text(endpoint.isEmpty ? "Endpoint belum diisi." : endpoint)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if apiKey.isEmpty {
                Button("Isi API key dulu") { showingSettings = true }
                    .font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: Capsule())
            }
            Text("Riwayat chat hanya tersimpan selama aplikasi dibuka — tutup aplikasi berarti mulai chat baru.")
                .font(.caption).foregroundStyle(.secondary)
            // Build stamp, so a screenshot always proves which build is installed.
            Text("Build \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private func bubble(_ message: AIChatMessage) -> some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 48) }
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 6) {
                if let att = message.attachment {
                    if att.isImage, let uiImage = UIImage(data: att.data) {
                        Image(uiImage: uiImage).resizable().scaledToFit()
                            .frame(maxWidth: 220, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.fill")
                            Text(att.fileName).lineLimit(1)
                            Text(att.displaySize).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(.tertiarySystemBackground), in: Capsule())
                    }
                }
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(
                        message.role == "user" ? Color.accentColor : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .foregroundStyle(message.role == "user" ? .white : .primary)
            }
            if message.role == "assistant" { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
        .id(message.id)
    }

    private var missingEndpoint: Bool {
        provider == .custom && endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil)
            && !isLoading && !apiKey.isEmpty && !model.isEmpty && !missingEndpoint
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
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let att = attachment
        guard !isLoading, !q.isEmpty || att != nil else { return }
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
        let userText = q.isEmpty ? "Jelaskan lampiran ini." : q
        draft = ""
        attachment = nil
        errorText = nil
        messages.append(AIChatMessage(role: "user", text: userText, attachment: att))
        let id = UUID()
        streamingID = id
        isLoading = true
        // Older attached messages keep only a name note in the history;
        // the fresh attachment rides as a media part on the newest message.
        let history: [(role: String, text: String)] = messages.dropLast().map { m -> (role: String, text: String) in
            (role: m.role, text: m.text + (m.attachment.map { " [Lampiran: \($0.fileName)]" } ?? ""))
        } + [(role: "user", text: userText)]
        AIClient.askChat(
            provider: provider, model: model, apiKey: apiKey, endpoint: endpoint, attachment: att, messages: history,
            onToken: { token in
                if let idx = messages.firstIndex(where: { $0.id == id }) {
                    messages[idx].text += token
                } else {
                    messages.append(AIChatMessage(id: id, role: "assistant", text: token))
                }
            },
            onDone: { message in
                isLoading = false
                streamingID = nil
                if let message {
                    errorText = message
                } else if messages.first(where: { $0.id == id }) == nil {
                    errorText = "Tidak ada jawaban dari \(provider.displayName). Coba cek model dan kunci API-nya."
                }
            }
        )
    }
}

// MARK: - AI chat settings (OpenAI-compatible format)

/// Provider, endpoint, model and key for the chat tab. Custom is any
/// OpenAI-compatible chat/completions endpoint: same request shape as
/// ChatGPT — POST, Bearer key, {"model","stream","messages"} — against
/// a user-supplied base URL. Keys go to the Keychain only.
private struct AIChatSettingsView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    @Binding var provider: AIProvider
    @Binding var model: String
    @Binding var endpoint: String
    @Binding var apiKey: String
    @Binding var keySaved: Bool

    /// API providers only: Meta has no public API, so it cannot chat
    /// from inside the app and is not offered here.
    private var providers: [AIProvider] { [.gemini, .chatgpt, .claude, .custom] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $provider) {
                        ForEach(providers) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(provider.keyInfo).font(.caption).foregroundStyle(.secondary)
                }
                Section("Endpoint & model") {
                    if provider == .custom {
                        TextField("https://contoh.com/v3", text: $endpoint)
                            .autocapitalization(.none).autocorrectionDisabled()
                        Text("URL dasar endpoint-nya — boleh juga ditempel lengkap sampai /chat/completions. Permintaan dikirim persis seperti contoh curl kemarin: POST, header Authorization Bearer, body model + messages.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Model", text: $model)
                        .autocapitalization(.none).autocorrectionDisabled()
                }
                Section("API key") {
                    SecureField("API key \(provider.displayName)", text: $apiKey)
                        .autocapitalization(.none).autocorrectionDisabled()
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
            .navigationTitle("Pengaturan AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Selesai") { dismiss() } } }
            .onChange(of: provider) { newValue in
                store.browserSettings.aiChatProvider = newValue.rawValue
                store.saveBrowserSettings()
                model = store.browserSettings.aiModels[newValue.rawValue] ?? newValue.defaultModel
                endpoint = store.browserSettings.aiCustomEndpoint
                let saved = KeychainHelper.load(account: newValue.rawValue) ?? ""
                apiKey = saved
                keySaved = !saved.isEmpty
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
    }
}
