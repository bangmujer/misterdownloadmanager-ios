import SwiftUI
import UIKit

// MARK: - Saved passwords list
//
// Hosts and usernames are listed freely, like Chrome's password list.
// The password itself is never shown without Face ID / passcode.

struct LoginGroup: Identifiable {
    let host: String
    let logins: [SavedLogin]
    var id: String { host }
}

struct PasswordsView: View {
    @EnvironmentObject var store: DownloadStore
    /// Set when the list is opened from the browser: tapping a login
    /// fills it into the open page (after Face ID). Nil from Settings,
    /// where there is no page to fill.
    var onFill: ((SavedLogin) -> Void)? = nil
    @State private var query = ""
    @State private var showingAdd = false
    @State private var editing: SavedLogin?

    private var groups: [LoginGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = store.passwords.logins.filter { login in
            q.isEmpty || login.host.localizedCaseInsensitiveContains(q)
                || login.username.localizedCaseInsensitiveContains(q)
        }
        // Group by the normalized host so an older entry saved as a full
        // URL sits under the same clean heading as the page it fills.
        let dict = Dictionary(grouping: all, by: { PasswordStore.normalizeHost($0.host) })
        return dict.keys.sorted().map { host in
            LoginGroup(host: host, logins: (dict[host] ?? []).sorted { $0.username < $1.username })
        }
    }

    var body: some View {
        List {
            if groups.isEmpty {
                Section {
                    Text(query.isEmpty
                         ? "Belum ada kata sandi tersimpan. Login di browser, dan saat formulir login dikirim, aplikasi akan menawarkan untuk menyimpannya."
                         : "Tidak ada login yang cocok dengan pencarian.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { group in
                Section(group.host) {
                    ForEach(group.logins) { login in
                        NavigationLink {
                            PasswordDetailView(login: login, onFill: onFill)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(login.username.isEmpty ? "(tanpa nama pengguna)" : login.username)
                                Text("Diperbarui \(login.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { store.passwords.delete(login) } label: {
                                Label("Hapus", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            Section {
                Text("Kata sandi hanya tersimpan di Keychain perangkat ini, tidak pernah dikirim ke mana pun. Melihat, menyalin, dan mengisi login selalu meminta Face ID (atau kode sandi perangkat). Login tidak disimpan dari tab Incognito.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "Cari situs atau nama pengguna")
        .navigationTitle("Kata Sandi")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack { PasswordEditView(login: nil) }
        }
        .sheet(item: $editing) { login in
            NavigationStack { PasswordEditView(login: login) }
        }
    }
}

// MARK: - One saved login

struct PasswordDetailView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    var login: SavedLogin
    var onFill: ((SavedLogin) -> Void)? = nil

    @State private var revealedPassword: String?
    @State private var authError: String?
    @State private var justCopied = false
    @State private var showingDeleteConfirm = false
    @State private var showingEdit = false

    var body: some View {
        // Re-read the login by id so the detail reflects edits made in
        // the edit sheet without navigating back to the list first.
        let current = store.passwords.logins.first { $0.id == login.id } ?? login
        return Form {
            if let onFill {
                Section {
                    Button {
                        onFill(current)
                        dismiss()
                    } label: {
                        Label("Isi otomatis di halaman ini", systemImage: "key.fill")
                    }
                    Text("Meminta Face ID, lalu mengisi kolom login di halaman yang sedang dibuka.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Situs") {
                LabeledContent("Situs", value: PasswordStore.normalizeHost(current.host))
                HStack {
                    LabeledContent("Nama pengguna", value: current.username.isEmpty ? "(tanpa nama pengguna)" : current.username)
                    Spacer()
                    Button { copyText(current.username, label: "Nama pengguna") } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .disabled(current.username.isEmpty)
                }
            }
            Section("Kata sandi") {
                HStack {
                    Text(revealedPassword ?? "••••••••••")
                        .font(revealedPassword == nil ? .body : .system(.body, design: .monospaced))
                    Spacer()
                    Button {
                        if revealedPassword != nil {
                            revealedPassword = nil
                        } else {
                            Task { await reveal() }
                        }
                    } label: {
                        Image(systemName: revealedPassword == nil ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.plain)
                    Button {
                        Task { await copyPassword() }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                }
                if justCopied {
                    Text("Tersalin ke clipboard.").font(.caption).foregroundStyle(.secondary)
                }
                if let authError {
                    Text(authError).font(.caption).foregroundStyle(.red)
                }
                Text("Melihat dan menyalin kata sandi memerlukan Face ID (atau kode sandi perangkat).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Ubah…") { showingEdit = true }
                Button("Hapus login ini", role: .destructive) { showingDeleteConfirm = true }
            }
        }
        .navigationTitle(PasswordStore.normalizeHost(current.host))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Hapus login ini?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Hapus", role: .destructive) {
                store.passwords.delete(login)
                dismiss()
            }
            Button("Batal", role: .cancel) {}
        } message: {
            Text("Login untuk \(current.host) akan dihapus dari perangkat ini.")
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack { PasswordEditView(login: current) }
        }
    }

    private func reveal() async {
        authError = nil
        guard await BiometricAuth.authenticate(reason: "Lihat kata sandi untuk \(login.host)") else {
            authError = "Autentikasi gagal — kata sandi tetap tersembunyi."
            return
        }
        revealedPassword = store.passwords.password(for: login) ?? ""
    }

    private func copyPassword() async {
        authError = nil
        guard await BiometricAuth.authenticate(reason: "Salin kata sandi untuk \(login.host)") else {
            authError = "Autentikasi gagal — kata sandi tidak disalin."
            return
        }
        guard let password = store.passwords.password(for: login) else { return }
        copyText(password, label: "Kata sandi")
    }

    private func copyText(_ text: String, label: String) {
        UIPasteboard.general.string = text
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { justCopied = false }
    }
}

// MARK: - Add / edit a login manually

struct PasswordEditView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) var dismiss
    var login: SavedLogin?

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showingPassword = false

    private var isEditing: Bool { login != nil }

    var body: some View {
        Form {
            Section {
                TextField("Situs (mis. google.com)", text: $host)
                    .autocapitalization(.none).autocorrectionDisabled()
                TextField("Nama pengguna", text: $username)
                    .autocapitalization(.none).autocorrectionDisabled()
                HStack {
                    Group {
                        if showingPassword {
                            TextField(passwordPlaceholder, text: $password)
                        } else {
                            SecureField(passwordPlaceholder, text: $password)
                        }
                    }
                    .autocapitalization(.none).autocorrectionDisabled()
                    Button {
                        showingPassword.toggle()
                    } label: {
                        Image(systemName: showingPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Kata sandi disimpan di Keychain perangkat ini. Saat mengubah login yang sudah ada, kosongkan kata sandi untuk mempertahankannya.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(isEditing ? "Ubah Login" : "Tambah Login")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Batal") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Simpan") { save() }
                    .disabled(!canSave)
            }
        }
        .onAppear {
            if let login {
                host = login.host
                username = login.username
            }
        }
    }

    private var passwordPlaceholder: String {
        isEditing ? "Kata sandi baru (kosongkan = tidak berubah)" : "Kata sandi"
    }

    private var canSave: Bool {
        !PasswordStore.normalizeHost(host).isEmpty && (!isEditing ? !password.isEmpty : true)
    }

    private func save() {
        let host = PasswordStore.normalizeHost(host)
        if let login {
            store.passwords.update(login, host: host, username: username, password: password)
        } else {
            store.passwords.save(host: host, username: username, password: password)
        }
        dismiss()
    }
}
