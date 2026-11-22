import Foundation
import CryptoKit

struct ProbeResult {
    var totalBytes: Int64?
    var acceptRanges: Bool
    var fileName: String?
    var mimeType: String?
    var finalURL: URL
}

/// Token-bucket-ish throttler shared by all segments of one download.
final class SpeedLimiter {
    private let limitBytesPerSec: Int64
    private var windowStart = Date()
    private var windowBytes: Int64 = 0
    private let lock = NSLock()
    init(limitKBps: Int) { limitBytesPerSec = Int64(limitKBps) * 1024 }
    var isLimited: Bool { limitBytesPerSec > 0 }
    func throttle(bytes: Int) {
        guard isLimited else { return }
        lock.lock()
        let now = Date()
        let elapsed = now.timeIntervalSince(windowStart)
        if elapsed >= 1 { windowStart = now; windowBytes = 0 }
        windowBytes += Int64(bytes)
        let expected = Double(windowBytes) / Double(limitBytesPerSec)
        let spent = Date().timeIntervalSince(windowStart)
        lock.unlock()
        if expected > spent {
            Thread.sleep(forTimeInterval: expected - spent)
        }
    }
}

final class RangeDownloadDelegate: NSObject, URLSessionDataDelegate {
    private let fileHandle: FileHandle
    private let onBytes: ((Int64) -> Void)?
    private let limiter: SpeedLimiter?
    private var continuation: CheckedContinuation<Int64, Error>?
    private(set) var bytesWritten: Int64 = 0
    private var responseError: Error?

    init(fileHandle: FileHandle, onBytes: ((Int64) -> Void)?, limiter: SpeedLimiter?) {
        self.fileHandle = fileHandle
        self.onBytes = onBytes
        self.limiter = limiter
    }

    func run(session: URLSession, request: URLRequest) async throws -> Int64 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int64, Error>) in
            self.continuation = cont
            let task = session.dataTask(with: request)
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            responseError = NSError(domain: "MDMDownload", code: code, userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(code)"])
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: data)
        } catch {
            responseError = error
            dataTask.cancel()
            return
        }
        bytesWritten += Int64(data.count)
        limiter?.throttle(bytes: data.count)
        onBytes?(Int64(data.count))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? fileHandle.close()
        if let err = error {
            // Cancellation surfaces as NSURLErrorCancelled (-999); keep it as-is so callers can tell pause apart.
            continuation?.resume(throwing: err)
        } else if let responseError {
            continuation?.resume(throwing: responseError)
        } else {
            continuation?.resume(returning: bytesWritten)
        }
        continuation = nil
    }
}

enum DownloadEngine {
    static func sessionConfiguration(settings: AppSettings) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 0
        config.waitsForConnectivity = true
        config.allowsCellularAccess = !settings.wifiOnly
        if settings.proxyEnabled, !settings.proxyHost.isEmpty {
            var proxy: [AnyHashable: Any] = [:]
            if settings.proxyType.uppercased() == "SOCKS" {
                proxy[kCFNetworkProxiesSOCKSEnable as String] = true
                proxy[kCFNetworkProxiesSOCKSProxy as String] = settings.proxyHost
                proxy[kCFNetworkProxiesSOCKSPort as String] = settings.proxyPort
            } else {
                proxy[kCFNetworkProxiesHTTPEnable as String] = true
                proxy[kCFNetworkProxiesHTTPProxy as String] = settings.proxyHost
                proxy[kCFNetworkProxiesHTTPPort as String] = settings.proxyPort
                proxy[kCFNetworkProxiesHTTPSEnable as String] = true
                proxy[kCFNetworkProxiesHTTPSProxy as String] = settings.proxyHost
                proxy[kCFNetworkProxiesHTTPSPort as String] = settings.proxyPort
            }
            config.connectionProxyDictionary = proxy
        }
        return config
    }

    static func makeRequest(url: URL, settings: AppSettings, referer: String?, range: ClosedRange<Int64>?) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(settings.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer, !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
        if let range { req.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        return req
    }

    static func probe(url: URL, settings: AppSettings, referer: String?) async throws -> ProbeResult {
        // Try a 1-byte range probe first: it reveals total size + resume support without downloading.
        var req = makeRequest(url: url, settings: settings, referer: referer, range: 0...0)
        req.httpMethod = "GET"
        let config = sessionConfiguration(settings: settings)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "MDMDownload", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"])
        }
        var total: Int64?
        if let cr = http.value(forHTTPHeaderField: "Content-Range") {
            // "bytes 0-0/12345"
            if let slash = cr.lastIndex(of: "/") {
                total = Int64(cr[cr.index(after: slash)...])
            }
        }
        if total == nil, let cl = http.value(forHTTPHeaderField: "Content-Length"), http.statusCode == 200 {
            total = Int64(cl)
        }
        let accept = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes") || http.statusCode == 206
        var fileName: String?
        if let cd = http.value(forHTTPHeaderField: "Content-Disposition"), let name = fileNameFromContentDisposition(cd) {
            fileName = name
        }
        return ProbeResult(totalBytes: total, acceptRanges: accept, fileName: fileName, mimeType: http.mimeType, finalURL: http.url ?? url)
    }

    static func fileNameFromContentDisposition(_ cd: String) -> String? {
        // filename*=UTF-8''... or filename="..."
        if let range = cd.range(of: "filename*=") {
            let rest = String(cd[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let parts = rest.components(separatedBy: "''")
            if parts.count == 2 { return parts[1].removingPercentEncoding }
            return rest.removingPercentEncoding
        }
        if let range = cd.range(of: "filename=") {
            var rest = String(cd[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("\"") { rest = String(rest.dropFirst()) }
            if let end = rest.firstIndex(of: "\"") { rest = String(rest[..<end]) }
            return rest
        }
        return nil
    }

    /// Streams one byte-range into `destination` (appending). Returns bytes written.
    static func downloadRange(url: URL, range: ClosedRange<Int64>?, destination: URL, settings: AppSettings, referer: String?, limiter: SpeedLimiter?, onBytes: ((Int64) -> Void)?) async throws -> Int64 {
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        let delegate = RangeDownloadDelegate(fileHandle: handle, onBytes: onBytes, limiter: limiter)
        let config = sessionConfiguration(settings: settings)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: OperationQueue())
        defer { session.finishTasksAndInvalidate() }
        let req = makeRequest(url: url, settings: settings, referer: referer, range: range)
        return try await delegate.run(session: session, request: req)
    }

    static func verifyChecksum(file: URL, type: String, expected: String) throws -> Bool {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let computed: String
        switch type.uppercased() {
        case "SHA256":
            computed = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "SHA1":
            computed = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "MD5":
            computed = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        default:
            return false
        }
        return computed.lowercased() == expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func sha256Hex(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
