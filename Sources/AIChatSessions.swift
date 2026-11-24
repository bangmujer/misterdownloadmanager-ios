import Foundation
import SwiftUI

// MARK: - AI chat sessions and projects (ChatGPT-style sidebar)
//
// Chats persist in mdm-ai-chats.json in the documents directory, so the
// sidebar survives restarts. A session belongs to at most one project;
// project-less sessions list under "Tanpa project". Attachments persist
// with their message only up to 2 MB of data — larger ones keep
// name/type/size, and their bubbles fall back to the document chip.

struct AIChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    var role: String // "user" or "assistant"
    var text: String
    var attachment: AIAttachment?
    /// Agent-mode tool activity for this answer, one line per call.
    /// Defaulted so chats saved before agent mode still decode.
    var toolLog: [String] = []

    // Explicit init: the synthesized memberwise init does not expose
    // `id` (it has a default value), and the streaming path needs to
    // construct a message with a known id to append tokens to.
    init(id: UUID = UUID(), role: String, text: String, attachment: AIAttachment? = nil, toolLog: [String] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.attachment = attachment
        self.toolLog = toolLog
    }
}

struct AIChatSession: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var projectID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var messages: [AIChatMessage]

    init(id: UUID = UUID(), title: String = "Chat baru", projectID: UUID? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date(), messages: [AIChatMessage] = []) {
        self.id = id
        self.title = title
        self.projectID = projectID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

struct AIChatProject: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// A conversation handed from the Ask AI sheet to the AI tab, carried
/// through the DownloadStore mailbox: the sheet sets it and dismisses,
/// the tab imports it as a saved session and the app switches tabs.
struct AIChatHandoff: Equatable {
    let id: UUID
    let title: String
    let messages: [AIChatMessage]

    init(title: String, messages: [AIChatMessage]) {
        self.id = UUID()
        self.title = title
        self.messages = messages
    }
}

final class AIChatStore: ObservableObject {
    @Published var sessions: [AIChatSession] = []
    @Published var projects: [AIChatProject] = []
    @Published var currentSessionID: UUID?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("mdm-ai-chats.json")
    }()

    init() { load() }

    var currentSession: AIChatSession? {
        sessions.first(where: { $0.id == currentSessionID })
    }

    func sessions(in project: AIChatProject?) -> [AIChatSession] {
        sessions.filter { $0.projectID == project?.id }.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func createSession() -> AIChatSession {
        let session = AIChatSession()
        sessions.insert(session, at: 0)
        currentSessionID = session.id
        save()
        return session
    }

    /// A conversation handed over from the Ask AI sheet: it becomes a
    /// saved session of its own, so it survives restarts like the rest.
    @discardableResult
    func importHandoff(title: String, messages: [AIChatMessage]) -> AIChatSession {
        let session = AIChatSession(title: title, messages: messages)
        sessions.insert(session, at: 0)
        currentSessionID = session.id
        save()
        return session
    }

    func ensureCurrentSession() {
        if currentSession == nil {
            if let first = sessions.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                currentSessionID = first.id
            } else {
                createSession()
            }
        }
    }

    /// Writes the working copy of the current chat back into its
    /// session. Does not save to disk — call save() after.
    func updateCurrent(messages: [AIChatMessage]) {
        guard let id = currentSessionID, let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].messages = messages
        sessions[idx].updatedAt = Date()
        if sessions[idx].title == "Chat baru",
           let first = messages.first(where: { $0.role == "user" }) {
            sessions[idx].title = chatTitle(from: first)
        }
    }

    private func chatTitle(from message: AIChatMessage) -> String {
        let single = message.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if single.isEmpty {
            return message.attachment.map { "Lampiran: \($0.fileName)" } ?? "Chat baru"
        }
        return String(single.prefix(40))
    }

    func move(_ session: AIChatSession, to projectID: UUID?) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx].projectID = projectID
        save()
    }

    func rename(_ session: AIChatSession, to title: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx].title = title
        save()
    }

    func delete(_ session: AIChatSession) {
        sessions.removeAll { $0.id == session.id }
        if currentSessionID == session.id {
            currentSessionID = nil
            ensureCurrentSession()
        }
        save()
    }

    @discardableResult
    func createProject(name: String) -> AIChatProject {
        let project = AIChatProject(name: name)
        projects.append(project)
        save()
        return project
    }

    func rename(_ project: AIChatProject, to name: String) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx].name = name
        save()
    }

    /// Deleting a project only ungroups its chats; the chats survive.
    func delete(_ project: AIChatProject) {
        projects.removeAll { $0.id == project.id }
        for idx in sessions.indices where sessions[idx].projectID == project.id {
            sessions[idx].projectID = nil
        }
        save()
    }

    func save() {
        let storable = sessions.map { session -> AIChatSession in
            var copy = session
            copy.messages = session.messages.map { message in
                var m = message
                if let att = m.attachment, att.data.count > 2 * 1024 * 1024 {
                    m.attachment = AIAttachment(fileName: att.fileName, mimeType: att.mimeType, data: Data(), isImage: att.isImage)
                }
                return m
            }
            return copy
        }
        let payload = SavedChats(sessions: storable, projects: projects, currentSessionID: currentSessionID)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(SavedChats.self, from: data) else { return }
        sessions = payload.sessions
        projects = payload.projects
        currentSessionID = payload.currentSessionID
    }

    private struct SavedChats: Codable {
        var sessions: [AIChatSession]
        var projects: [AIChatProject]
        var currentSessionID: UUID?
    }
}
