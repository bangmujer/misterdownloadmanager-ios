import Combine
import Foundation
import LocalAuthentication
import Security

// MARK: - Face ID / device passcode gate
//
// Viewing a saved password and filling a saved login always require
// authentication first, like Safari and Chrome. Face ID / Touch ID is
// tried first; when biometrics are unavailable or not enrolled the
// device passcode is accepted instead, so the user is never locked
// out of their own saved logins.

enum BiometricAuth {
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Batal"
        let usablePolicy: LAPolicy
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            usablePolicy = .deviceOwnerAuthenticationWithBiometrics
        } else if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
            usablePolicy = .deviceOwnerAuthentication
        } else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(usablePolicy, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

// MARK: - Saved login
//
// The password itself lives ONLY in the device Keychain (one generic
// item per login, keyed by the login's id). This struct — host,
// username, dates — is the only thing written to a JSON file, so a
// backup of the app's files never contains a password.

struct SavedLogin: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var host: String
    var username: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

/// A save prompt captured from a submitted login form.
struct SaveLoginPrompt: Equatable {
    let host: String
    let username: String
    let password: String
}

/// An autofill offer for the page currently open.
struct AutofillOffer: Equatable {
    let host: String
    let logins: [SavedLogin]
}

final class PasswordStore: ObservableObject {
    static let keychainService = "com.bangmujer.misterdownloadmanager.passwords"

    @Published private(set) var logins: [SavedLogin] = []

    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("mdm-logins.json")

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([SavedLogin].self, from: data) {
            logins = decoded
        }
    }

    // MARK: - Lookup

    /// Saved logins that apply to a page host (exact host or any
    /// subdomain of it, e.g. a login saved on google.com also fills on
    /// mail.google.com), newest first.
    func logins(forHost host: String) -> [SavedLogin] {
        let host = Self.normalizeHost(host)
        return logins.filter { Self.hostMatches(page: host, saved: $0.host) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func password(for login: SavedLogin) -> String? {
        Self.keychainLoad(account: login.id.uuidString)
    }

    // MARK: - Mutations

    /// Insert or update the login for a (host, username) pair.
    func save(host: String, username: String, password: String) {
        let host = Self.normalizeHost(host)
        if let idx = logins.firstIndex(where: { Self.normalizeHost($0.host) == host && $0.username == username }) {
            // Heal an older entry whose stored host was a full URL.
            logins[idx].host = host
            logins[idx].updatedAt = Date()
            Self.keychainSave(account: logins[idx].id.uuidString, value: password)
        } else {
            let login = SavedLogin(host: host, username: username)
            logins.append(login)
            Self.keychainSave(account: login.id.uuidString, value: password)
        }
        persist()
    }

    /// Update host/username, and the password only when a new one is given
    /// (an empty password keeps the stored one).
    func update(_ login: SavedLogin, host: String, username: String, password: String) {
        guard let idx = logins.firstIndex(where: { $0.id == login.id }) else { return }
        logins[idx].host = Self.normalizeHost(host)
        logins[idx].username = username
        logins[idx].updatedAt = Date()
        if !password.isEmpty {
            Self.keychainSave(account: login.id.uuidString, value: password)
        }
        persist()
    }

    func delete(_ login: SavedLogin) {
        logins.removeAll { $0.id == login.id }
        Self.keychainDelete(account: login.id.uuidString)
        persist()
    }

    // MARK: - Host matching

    static func normalizeHost(_ host: String) -> String {
        var h = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return h }
        // A full URL pasted as the host (http://10.128.4.218:5000/inspection/)
        // must reduce to its bare host, or it will never match the page
        // that reported location.hostname.
        if let url = URL(string: h), let urlHost = url.host, !urlHost.isEmpty {
            h = urlHost
        } else {
            if let schemeRange = h.range(of: "://") { h = String(h[schemeRange.upperBound...]) }
            let cut = [Character("?"), "#", "/"].compactMap { h.firstIndex(of: $0) }.min()
            if let cut { h = String(h[..<cut]) }
            if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
            if let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
        }
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        if h.hasSuffix(".") { h = String(h.dropLast()) }
        return h
    }

    static func hostMatches(page: String, saved: String) -> Bool {
        // Normalize both sides: entries saved by older builds may hold a
        // full URL as the host, and they must still match their page.
        let page = normalizeHost(page)
        let saved = normalizeHost(saved)
        guard !page.isEmpty, !saved.isEmpty else { return false }
        return page == saved || page.hasSuffix("." + saved) || saved.hasSuffix("." + page)
    }

    // MARK: - Metadata persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(logins) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Keychain (passwords only)

    private static func keychainLoad(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainSave(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
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

    private static func keychainDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - In-page login scripts

    /// Detects a login form on the page and reports submissions to the
    /// native `mdmLogin` handler. The password VALUE is only included
    /// in `submitted` reports (never in `detected`), stays in-process,
    /// and is never logged or sent anywhere.
    static let detectionScript = """
    (function() {
      if (window.__mdmLoginInstalled) return; window.__mdmLoginInstalled = true;
      function pwField() {
        var els = document.querySelectorAll('input[type="password"]');
        for (var i = 0; i < els.length; i++) { if (!els[i].disabled && els[i].offsetParent !== null) return els[i]; }
        return els.length ? els[0] : null;
      }
      function userField(pw) {
        var u = document.querySelector('input[autocomplete="username"], input[autocomplete="email"]');
        if (u && !u.disabled) return u;
        var scope = (pw && pw.form) ? pw.form.querySelectorAll('input') : document.querySelectorAll('input');
        var last = null;
        for (var i = 0; i < scope.length; i++) {
          var el = scope[i];
          if (pw && el === pw) break;
          var t = (el.type || '').toLowerCase();
          if (t === 'text' || t === 'email' || t === 'tel' || t === '') last = el;
        }
        return last;
      }
      function postSubmitted() {
        var pw = pwField(); if (!pw) return;
        var u = userField(pw);
        try { window.webkit.messageHandlers.mdmLogin.postMessage({ type: 'submitted', host: location.hostname, username: u ? (u.value || '') : '', password: pw.value || '' }); } catch (e) {}
      }
      function reportDetected() {
        if (!pwField()) return;
        try { window.webkit.messageHandlers.mdmLogin.postMessage({ type: 'detected', host: location.hostname }); } catch (e) {}
      }
      if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', reportDetected); } else { reportDetected(); }
      setTimeout(reportDetected, 1500);
      // Re-check when the user taps into a login field: forms rendered
      // late by JavaScript miss the load-time checks above.
      document.addEventListener('focusin', function(e) {
        var t = e.target;
        if (t && (t.type === 'password' || t.type === 'text' || t.type === 'email' || t.type === 'tel')) reportDetected();
      }, true);
      document.addEventListener('submit', function() { setTimeout(postSubmitted, 60); }, true);
      document.addEventListener('keydown', function(e) {
        if (e.key === 'Enter' && e.target && e.target.type === 'password') setTimeout(postSubmitted, 60);
      }, true);
      document.addEventListener('click', function(e) {
        var t = e.target && e.target.closest ? e.target.closest('button[type="submit"], input[type="submit"]') : null;
        if (t) setTimeout(postSubmitted, 80);
      }, true);
    })();
    """

    /// Fills the page's username/password fields, using the native value
    /// setter so React- and framework-controlled inputs notice the change.
    static func fillScript(username: String, password: String) -> String {
        let userJSON = jsonString(username)
        let passJSON = jsonString(password)
        return """
        (function() {
          function setVal(el, v) {
            var desc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
            if (desc && desc.set) { desc.set.call(el, v); } else { el.value = v; }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
          var pw = document.querySelector('input[type="password"]:not([disabled])');
          if (!pw) return false;
          var u = document.querySelector('input[autocomplete="username"], input[autocomplete="email"]');
          if (!u) {
            var scope = pw.form ? pw.form.querySelectorAll('input') : document.querySelectorAll('input');
            for (var i = 0; i < scope.length; i++) {
              if (scope[i] === pw) break;
              var t = (scope[i].type || '').toLowerCase();
              if (t === 'text' || t === 'email' || t === 'tel' || t === '') u = scope[i];
            }
          }
          if (u) setVal(u, \(userJSON));
          setVal(pw, \(passJSON));
          return true;
        })();
        """
    }

    /// A JSON string literal for one string — safe to interpolate into JS.
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              var text = String(data: data, encoding: .utf8), text.count >= 2 else { return "\"\"" }
        text.removeFirst()
        text.removeLast()
        return text
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
