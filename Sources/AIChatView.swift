import SwiftUI

// MARK: - AI chat tab
//
// A dedicated chat column next to the Browser tab. It talks to the same
// providers as the Ask AI sheet, but keeps a multi-turn history, and its
// own provider choice defaults to Custom — any OpenAI-compatible
// chat/completions endpoint (the format from the user's own gateway),
// configured with a base URL, a model name and an API key. Chats persist
// in sessions grouped into projects, Kimi-style, via AIChatStore.

struct AIChatView: View {
    @EnvironmentObject var store: DownloadStore
    @StateObject private var chatStore = AIChatStore()
    @State private var showingSidebar = false
    @State private var sidebarSearch = ""
    @State private var collapsedProjects: Set<UUID> = []
    @State private var projectsSectionExpanded = true
    @State private var newProjectName = ""
    @State private var showingNewProject = false
    @State private var renamingSession: AIChatSession?
    @State private var renamingProject: AIChatProject?
    @State private var renameText = ""
    @State private var showingRename = false
    @State private var deletingSession: AIChatSession?
    @State private var showingDeleteSession = false
    @State private var deletingProject: AIChatProject?
    @State private var showingDeleteProject = false
    @State private var didLoadSession = false
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
    @State private var failedIDs: Set<UUID> = []
    @State private var editingMessageID: UUID?
    @State private var stashedDraft = ""
    @State private var pendingHandoff: AIChatHandoff?
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
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
                    // Keyboard dismissal: drag the messages down to
                    // dismiss interactively (like any chat app), or tap
                    // a message — otherwise the keyboard covers the tab
                    // bar and the user cannot switch tabs.
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture { inputFocused = false }
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
                if editingMessageID != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                        Text("Mengubah pesan").font(.subheadline)
                        Spacer()
                        Button("Batal") { cancelEdit() }
                    }
                    .foregroundStyle(.secondary)
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
                            Image(systemName: editingMessageID == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill")
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
                    Button { showingSidebar = true } label: {
                        Label("Daftar chat", systemImage: "sidebar.left")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingSettings = true } label: {
                        Label("Pengaturan AI", systemImage: "gearshape")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button { inputFocused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .accessibilityLabel("Sembunyikan keyboard")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                AIChatSettingsView(provider: $provider, model: $model, endpoint: $endpoint, apiKey: $apiKey, keySaved: $keySaved)
            }
        }
        .onDisappear { inputFocused = false }
        .onAppear {
            provider = AIProvider(rawValue: store.browserSettings.aiChatProvider) ?? .custom
            if provider == .meta { provider = .custom }
            loadModelAndKey()
            if !didLoadSession {
                didLoadSession = true
                chatStore.ensureCurrentSession()
                messages = chatStore.currentSession?.messages ?? []
            }
        }
        .onChange(of: messages) { _ in
            if !isLoading { persist() }
        }
        .onChange(of: store.aiHandoff) { handoff in
            guard let handoff else { return }
            // Never swap the chat under a running stream: the tokens
            // would land in the imported chat as a stray answer.
            if isLoading {
                pendingHandoff = handoff
            } else {
                importHandoff(handoff)
            }
        }
        .onChange(of: isLoading) { loading in
            if !loading, let handoff = pendingHandoff {
                pendingHandoff = nil
                importHandoff(handoff)
            }
        }
        .alert("Proyek baru", isPresented: $showingNewProject) {
            TextField("Nama proyek", text: $newProjectName)
            Button("Batal", role: .cancel) { newProjectName = "" }
            Button("Buat") {
                let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { chatStore.createProject(name: name) }
                newProjectName = ""
            }
        }
        .alert("Ubah nama", isPresented: $showingRename) {
            TextField("Nama", text: $renameText)
            Button("Batal", role: .cancel) { renamingSession = nil; renamingProject = nil }
            Button("Simpan") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    if let session = renamingSession { chatStore.rename(session, to: name) }
                    if let project = renamingProject { chatStore.rename(project, to: name) }
                }
                renamingSession = nil; renamingProject = nil
            }
        }
        .alert("Hapus chat ini?", isPresented: $showingDeleteSession) {
            Button("Hapus", role: .destructive) {
                if let session = deletingSession {
                    let wasCurrent = session.id == chatStore.currentSessionID
                    chatStore.delete(session)
                    if wasCurrent { messages = chatStore.currentSession?.messages ?? [] }
                    failedIDs = []; editingMessageID = nil; errorText = nil
                }
                deletingSession = nil
            }
            Button("Batal", role: .cancel) { deletingSession = nil }
        } message: {
            Text("Chat yang dihapus tidak bisa dikembalikan.")
        }
        .alert("Hapus proyek ini?", isPresented: $showingDeleteProject) {
            Button("Hapus", role: .destructive) {
                if let project = deletingProject { chatStore.delete(project) }
                deletingProject = nil
            }
            Button("Batal", role: .cancel) { deletingProject = nil }
        } message: {
            Text("Chat di dalamnya tidak ikut terhapus, hanya pindah ke Obrolan.")
        }
            if showingSidebar {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { showingSidebar = false }
                sidebar
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.default, value: showingSidebar)
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
            Text("Chat tersimpan di perangkat ini — buka sidebar untuk melihat proyek dan chat lama.")
                .font(.caption).foregroundStyle(.secondary)
            // Build stamp, so a screenshot always proves which build is installed.
            Text("Build \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    // MARK: - Sidebar: projects (Kimi-style) and chats

    private var sidebar: some View {
        VStack(spacing: 0) {
            Button { startNewChat() } label: {
                Label("Chat baru", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    DisclosureGroup(isExpanded: $projectsSectionExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            Button { showingNewProject = true } label: {
                                Label("Proyek baru", systemImage: "folder.badge.plus")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                            ForEach(filteredProjects) { project in
                                projectGroup(project)
                            }
                        }
                    } label: {
                        Text("Proyek").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 12)
                    Text("Obrolan").font(.subheadline).foregroundStyle(.secondary)
                        .padding(.top, 12)
                    ForEach(ungroupedChats) { session in
                        chatRow(session)
                    }
                    if chatStore.sessions.isEmpty {
                        Text("Belum ada chat.").foregroundStyle(.secondary).font(.subheadline).padding(.top, 16)
                    }
                }
                .padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Cari", text: $sidebarSearch)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: Capsule())
                Button { showingSidebar = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
        }
        .frame(width: 300)
        .background(Color(.systemBackground))
    }

    private func projectGroup(_ project: AIChatProject) -> some View {
        DisclosureGroup(isExpanded: projectExpandedBinding(for: project)) {
            ForEach(projectChats(project)) { session in
                chatRow(session)
            }
        } label: {
            projectLabel(project)
        }
    }

    private func projectLabel(_ project: AIChatProject) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(project.name).font(.subheadline).lineLimit(1)
            Spacer()
            Text("\(chatStore.sessions(in: project).count)").font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button { renamingProject = project; renameText = project.name; showingRename = true } label: { Label("Ubah nama", systemImage: "pencil") }
            Button("Hapus proyek", role: .destructive) { deletingProject = project; showingDeleteProject = true }
        }
    }

    private func chatRow(_ session: AIChatSession) -> some View {
        Button { openSession(session) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).lineLimit(2).font(.subheadline)
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.id == chatStore.currentSessionID {
                    Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(session.id == chatStore.currentSessionID ? Color(.secondarySystemBackground) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { renamingSession = session; renameText = session.title; showingRename = true } label: { Label("Ubah nama", systemImage: "pencil") }
            Menu("Pindahkan ke proyek") {
                Button("Tanpa proyek") { chatStore.move(session, to: nil) }
                ForEach(chatStore.projects) { project in
                    Button(project.name) { chatStore.move(session, to: project.id) }
                }
            }
            Button("Hapus", role: .destructive) { deletingSession = session; showingDeleteSession = true }
        }
    }

    private var searchQuery: String {
        sidebarSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matchesSearch(_ session: AIChatSession) -> Bool {
        searchQuery.isEmpty || session.title.lowercased().contains(searchQuery)
    }

    private var filteredProjects: [AIChatProject] {
        chatStore.projects.filter { project in
            searchQuery.isEmpty
                || project.name.lowercased().contains(searchQuery)
                || chatStore.sessions(in: project).contains(where: matchesSearch)
        }
    }

    private func projectChats(_ project: AIChatProject) -> [AIChatSession] {
        let all = chatStore.sessions(in: project)
        if searchQuery.isEmpty || project.name.lowercased().contains(searchQuery) { return all }
        return all.filter(matchesSearch)
    }

    private var ungroupedChats: [AIChatSession] {
        chatStore.sessions(in: nil).filter(matchesSearch)
    }

    private func projectExpandedBinding(for project: AIChatProject) -> Binding<Bool> {
        Binding(
            get: { !collapsedProjects.contains(project.id) || !searchQuery.isEmpty },
            set: { expanded in
                if expanded { collapsedProjects.remove(project.id) } else { collapsedProjects.insert(project.id) }
            }
        )
    }

    private func persist() {
        chatStore.updateCurrent(messages: messages)
        chatStore.save()
    }

    /// Takes a conversation handed over from the Ask AI sheet and
    /// opens it as the current saved session.
    private func importHandoff(_ handoff: AIChatHandoff) {
        persist()
        let session = chatStore.importHandoff(title: handoff.title, messages: handoff.messages)
        messages = session.messages
        failedIDs = []
        editingMessageID = nil
        errorText = nil
        draft = ""
        attachment = nil
        store.aiHandoff = nil
    }

    private func openSession(_ session: AIChatSession) {
        persist()
        chatStore.currentSessionID = session.id
        chatStore.save()
        messages = session.messages
        failedIDs = []
        editingMessageID = nil
        errorText = nil
        draft = ""
        attachment = nil
        showingSidebar = false
    }

    private func startNewChat() {
        if let current = chatStore.currentSession, current.messages.isEmpty {
            messages = []
            failedIDs = []
            editingMessageID = nil
            errorText = nil
            draft = ""
            attachment = nil
            showingSidebar = false
            inputFocused = true
            return
        }
        persist()
        chatStore.createSession()
        messages = []
        failedIDs = []
        editingMessageID = nil
        errorText = nil
        draft = ""
        attachment = nil
        showingSidebar = false
        inputFocused = true
    }

    private func bubble(_ message: AIChatMessage) -> some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
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
                if message.role == "assistant" {
                    // Assistant answers render Markdown ChatGPT-style:
                    // headings, bold, code blocks with a copy button,
                    // tables, lists. Long-press selects the text, so
                    // an answer can be blocked and copied.
                    MarkdownChatView(text: message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.primary)
                } else {
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
            }
                if message.role == "assistant" { Spacer(minLength: 48) }
            }
            if message.role == "user", failedIDs.contains(message.id) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("Tidak terkirim.").foregroundStyle(.secondary)
                    Button("Kirim ulang") { retry(message) }
                        .disabled(isLoading)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
        .id(message.id)
        .contextMenu {
            if message.role == "user" {
                Button { beginEdit(message) } label: { Label("Ubah pesan", systemImage: "pencil") }
                    .disabled(isLoading)
                Button { UIPasteboard.general.string = message.text } label: { Label("Salin", systemImage: "doc.on.doc") }
            }
        }
    }

    private var missingEndpoint: Bool {
        provider == .custom && endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        let textPresent = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // While editing, only the edited text counts — a staged
        // attachment belongs to the next fresh message, not the edit.
        let contentOK = editingMessageID != nil ? textPresent : (textPresent || attachment != nil)
        return contentOK && !isLoading && !apiKey.isEmpty && !model.isEmpty && !missingEndpoint
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
        // Confirming an edit re-sends the edited message instead of
        // appending a new one.
        if editingMessageID != nil { confirmEdit(); return }
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
        let userMessage = AIChatMessage(role: "user", text: userText, attachment: att)
        messages.append(userMessage)
        startRequest(for: userMessage)
    }

    /// Sends (or re-sends) one user message: builds the history up to
    /// it — older attachments ride only as name notes — and streams the
    /// answer. A failed attempt marks the message so its bubble can
    /// offer "Kirim ulang".
    private func startRequest(for userMessage: AIChatMessage) {
        guard let idx = messages.firstIndex(where: { $0.id == userMessage.id }) else { return }
        failedIDs.remove(userMessage.id)
        let id = UUID()
        streamingID = id
        isLoading = true
        errorText = nil
        // Older attached messages keep only a name note in the history;
        // the fresh attachment rides as a media part on the newest message.
        let prefix = messages[...idx]
        let history: [(role: String, text: String)] = prefix.dropLast().map { m -> (role: String, text: String) in
            (role: m.role, text: m.text + (m.attachment.map { " [Lampiran: \($0.fileName)]" } ?? ""))
        } + [(role: "user", text: userMessage.text)]
        AIClient.askChat(
            provider: provider, model: model, apiKey: apiKey, endpoint: endpoint, attachment: userMessage.attachment, messages: history,
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
                let gotAnswer = messages.contains(where: { $0.id == id })
                if let message {
                    errorText = message
                } else if !gotAnswer {
                    errorText = "Tidak ada jawaban dari \(provider.displayName). Coba cek model dan kunci API-nya."
                }
                if message != nil || !gotAnswer {
                    failedIDs.insert(userMessage.id)
                }
                persist()
            }
        )
    }

    /// Re-sends a failed message with its original attachment. Any
    /// replies after it (including a partial answer) are dropped and
    /// regenerated.
    private func retry(_ message: AIChatMessage) {
        guard !isLoading,
              let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let droppedIDs = messages[(idx + 1)...].map(\.id)
        failedIDs.subtract(droppedIDs)
        messages = Array(messages[...idx])
        startRequest(for: messages[idx])
    }

    private func beginEdit(_ message: AIChatMessage) {
        guard !isLoading else { return }
        stashedDraft = draft
        draft = message.text
        editingMessageID = message.id
        inputFocused = true
    }

    private func cancelEdit() {
        draft = stashedDraft
        stashedDraft = ""
        editingMessageID = nil
    }

    /// Applies the edited text, drops everything after the message
    /// (its old answer included), and re-sends it with the original
    /// attachment.
    private func confirmEdit() {
        guard let editID = editingMessageID,
              let idx = messages.firstIndex(where: { $0.id == editID }),
              !isLoading else { return }
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let droppedIDs = messages[(idx + 1)...].map(\.id)
        failedIDs.subtract(droppedIDs)
        messages[idx].text = q
        messages = Array(messages[...idx])
        draft = ""
        attachment = nil
        stashedDraft = ""
        editingMessageID = nil
        startRequest(for: messages[idx])
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
    private var providers: [AIProvider] { [.gemini, .chatgpt, .claude, .balitech, .custom] }

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
