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
    let id = UUID()
    var role: String // "user" or "assistant"
    var text: String
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
                HStack(alignment: .bottom, spacing: 8) {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private func bubble(_ message: AIChatMessage) -> some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 48) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(
                    message.role == "user" ? Color.accentColor : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .foregroundStyle(message.role == "user" ? .white : .primary)
            if message.role == "assistant" { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
        .id(message.id)
    }

    private var missingEndpoint: Bool {
        provider == .custom && endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isLoading && !apiKey.isEmpty && !model.isEmpty && !missingEndpoint
    }

    private func loadModelAndKey() {
        model = store.browserSettings.aiModels[provider.rawValue] ?? provider.defaultModel
        endpoint = store.browserSettings.aiCustomEndpoint
        let saved = KeychainHelper.load(account: provider.rawValue) ?? ""
        apiKey = saved
        keySaved = !saved.isEmpty
    }

    private func send() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isLoading else { return }
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
        draft = ""
        errorText = nil
        messages.append(AIChatMessage(role: "user", text: q))
        let id = UUID()
        streamingID = id
        isLoading = true
        let history = messages.map { (role: $0.role, text: $0.text) }
        AIClient.askChat(
            provider: provider, model: model, apiKey: apiKey, endpoint: endpoint, messages: history,
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
