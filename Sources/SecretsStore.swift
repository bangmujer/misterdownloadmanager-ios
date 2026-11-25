import Foundation
import Security

/// Secrets that must never live in the plaintext JSON state files.
///
/// Three groups share one Keychain service (`...secrets`, separate from
/// the AI-key service): the LAN remote pairing token, the five debrid
/// keys, and API Tester auth secrets. The JSON files keep metadata only.
/// Old plaintext values are migrated once on load (see the two
/// `migrate…` functions) and then cleared from the JSON.
enum MDMSecrets {
    static let service = "com.bangmujer.misterdownloadmanager.secrets"

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

    static func save(_ value: String, account: String) {
        if value.isEmpty {
            delete(account: account)
            return
        }
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

    // MARK: - LAN remote pairing token (S1)

    private static let remoteTokenAccount = "remote-pairing-token"

    static func currentRemoteToken() -> String? { load(account: remoteTokenAccount) }

    /// Returns the existing token, generating and storing one first when
    /// none exists yet. Called whenever the remote server starts, so a
    /// token always exists while the server runs.
    @discardableResult
    static func ensureRemoteToken() -> String {
        if let token = currentRemoteToken(), !token.isEmpty { return token }
        let token = UUID().uuidString
        save(token, account: remoteTokenAccount)
        return token
    }

    /// Revokes the current token and issues a new one. Takes effect
    /// immediately: the server reads the token fresh on every request.
    @discardableResult
    static func regenerateRemoteToken() -> String {
        let token = UUID().uuidString
        save(token, account: remoteTokenAccount)
        return token
    }

    // MARK: - Debrid keys (S4)

    static func debridAccount(for service: DebridService) -> String {
        "debrid-\(service.rawValue)"
    }

    static func debridKey(for service: DebridService) -> String {
        load(account: debridAccount(for: service)) ?? ""
    }

    static func saveDebridKey(_ value: String, for service: DebridService) {
        save(value, account: debridAccount(for: service))
    }

    static func hasDebridKey(for service: DebridService) -> Bool {
        !debridKey(for: service).isEmpty
    }

    static func deleteDebridKey(for service: DebridService) {
        delete(account: debridAccount(for: service))
    }

    /// One-time migration: moves any plaintext debrid keys out of the
    /// settings struct into the Keychain and clears the struct fields.
    /// Returns true when anything moved (caller saves the state file).
    @discardableResult
    static func migrateDebridKeys(settings: inout AppSettings) -> Bool {
        var moved = false
        for service in DebridService.allCases {
            let current: String
            switch service {
            case .realDebrid: current = settings.realDebridKey
            case .allDebrid: current = settings.allDebridKey
            case .premiumize: current = settings.premiumizeKey
            case .torbox: current = settings.torboxKey
            case .megaDebrid: current = settings.megaDebridKey
            }
            guard !current.isEmpty else { continue }
            if debridKey(for: service).isEmpty {
                saveDebridKey(current, for: service)
            }
            switch service {
            case .realDebrid: settings.realDebridKey = ""
            case .allDebrid: settings.allDebridKey = ""
            case .premiumize: settings.premiumizeKey = ""
            case .torbox: settings.torboxKey = ""
            case .megaDebrid: settings.megaDebridKey = ""
            }
            moved = true
        }
        return moved
    }

    // MARK: - API Tester auth secrets (S4)

    static func apiSecretsAccount(for requestID: UUID) -> String {
        "api-auth-\(requestID.uuidString)"
    }

    static func loadApiSecrets(for requestID: UUID) -> ApiAuthSecrets {
        guard let raw = load(account: apiSecretsAccount(for: requestID)),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ApiAuthSecrets.self, from: data) else {
            return ApiAuthSecrets()
        }
        return decoded
    }

    static func saveApiSecrets(_ secrets: ApiAuthSecrets, for requestID: UUID) {
        if secrets.isEmpty {
            delete(account: apiSecretsAccount(for: requestID))
            return
        }
        if let data = try? JSONEncoder().encode(secrets),
           let raw = String(data: data, encoding: .utf8) {
            save(raw, account: apiSecretsAccount(for: requestID))
        }
    }

    static func deleteApiSecrets(for requestID: UUID) {
        delete(account: apiSecretsAccount(for: requestID))
    }

    /// One-time migration: moves plaintext password/token/key out of a
    /// decoded request into the Keychain (keyed by the request's stable
    /// id) and clears the struct fields. Returns true when anything moved.
    @discardableResult
    static func migrateApiRequest(_ request: inout ApiRequest) -> Bool {
        let secrets = ApiAuthSecrets(
            password: request.auth.password,
            token: request.auth.token,
            key: request.auth.key
        )
        guard !secrets.isEmpty else { return false }
        let existing = loadApiSecrets(for: request.id)
        if existing.isEmpty {
            saveApiSecrets(secrets, for: request.id)
        }
        request.auth.password = ""
        request.auth.token = ""
        request.auth.key = ""
        return true
    }
}

/// The secret half of an API Tester auth block. Only the kind, the Basic
/// username, and the API-key header name stay in the request JSON; the
/// password, bearer token, and key value live here, in the Keychain.
struct ApiAuthSecrets: Codable, Equatable {
    var password = ""
    var token = ""
    var key = ""

    var isEmpty: Bool { password.isEmpty && token.isEmpty && key.isEmpty }
}
