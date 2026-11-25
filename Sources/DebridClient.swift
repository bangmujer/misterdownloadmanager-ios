import Foundation

/// Debrid unrestricting through each service's official API, using the user's own key.
/// Mirrors MDM's debrid crate (Real-Debrid, AllDebrid, Premiumize, TorBox, Mega-Debrid).
/// Keys live only in the device Keychain (see MDMSecrets); nothing is sent anywhere else.
enum DebridService: String, CaseIterable, Identifiable {
    case realDebrid = "Real-Debrid"
    case allDebrid = "AllDebrid"
    case premiumize = "Premiumize"
    case torbox = "TorBox"
    case megaDebrid = "Mega-Debrid"
    var id: String { rawValue }
}

enum DebridClient {
    static func key(for service: DebridService) -> String {
        MDMSecrets.debridKey(for: service)
    }

    /// Returns a direct download URL for a file-host link, or throws with the service's message.
    static func unrestrict(_ link: String, service: DebridService) async throws -> String {
        let key = key(for: service).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw NSError(domain: "MDMDebrid", code: 401, userInfo: [NSLocalizedDescriptionKey: "Masukkan API key \(service.rawValue) dulu di Pengaturan → Debrid."]) }
        guard let linkURL = URL(string: link) else { throw NSError(domain: "MDMDebrid", code: 400, userInfo: [NSLocalizedDescriptionKey: "Link tidak valid."]) }

        var request: URLRequest
        switch service {
        case .realDebrid:
            request = URLRequest(url: URL(string: "https://api.real-debrid.com/rest/1.0/unrestrict/link")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = "link=\(link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? link)".data(using: .utf8)
        case .allDebrid:
            var comps = URLComponents(string: "https://api.alldebrid.com/v4/link/unlock")!
            comps.queryItems = [URLQueryItem(name: "agent", value: "mdm-ios"), URLQueryItem(name: "apikey", value: key), URLQueryItem(name: "link", value: link)]
            request = URLRequest(url: comps.url!)
        case .premiumize:
            var comps = URLComponents(string: "https://www.premiumize.me/api/transfer/directdl")!
            comps.queryItems = [URLQueryItem(name: "apikey", value: key), URLQueryItem(name: "src", value: link)]
            request = URLRequest(url: comps.url!)
        case .torbox:
            var comps = URLComponents(string: "https://api.torbox.app/v1/api/torrents/requestdl")!
            comps.queryItems = [URLQueryItem(name: "token", value: key), URLQueryItem(name: "magnet", value: link)]
            // TorBox also accepts a plain link via /link; magnet path is the common one.
            request = URLRequest(url: comps.url!)
            _ = linkURL
        case .megaDebrid:
            var comps = URLComponents(string: "https://www.mega-debrid.eu/api.php")!
            comps.queryItems = [URLQueryItem(name: "action", value: "getLink"), URLQueryItem(name: "token", value: key), URLQueryItem(name: "link", value: link)]
            request = URLRequest(url: comps.url!)
        }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else {
            throw NSError(domain: "MDMDebrid", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: [NSLocalizedDescriptionKey: "Layanan debrid menolak permintaan (periksa key / kuota)."])
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        // Walk the usual shapes: {download}, {data:{link|download|location}}, {link}, {location}
        if let direct = json["download"] as? String, !direct.isEmpty { return direct }
        if let direct = json["link"] as? String, !direct.isEmpty { return direct }
        if let direct = json["location"] as? String, !direct.isEmpty { return direct }
        if let dataDict = json["data"] as? [String: Any] {
            for k in ["link", "download", "location", "directlink"] {
                if let v = dataDict[k] as? String, !v.isEmpty { return v }
            }
        }
        let msg = (json["error"] as? String) ?? (json["message"] as? String) ?? "Respons debrid tidak dikenali."
        throw NSError(domain: "MDMDebrid", code: 422, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
