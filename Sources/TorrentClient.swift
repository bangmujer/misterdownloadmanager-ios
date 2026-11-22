import Foundation
import CryptoKit
import Network

/// Minimal BitTorrent support for iOS: bencode parsing, .torrent / magnet
/// metadata, tracker announce, and a sequential single-peer piece downloader.
/// This is intentionally the desktop client's smaller cousin: no DHT, no
/// uTP, no UPnP, no seeding in background, no multi-torrent swarm — iOS
/// sandboxing and background limits do not allow the full librqbit behaviour.
/// Multi-file torrents list their files and download the first selected file;
/// the rest are reported as unsupported in the UI rather than silently skipped.
indirect enum BValue {
    case int(Int64)
    case bytes(Data)
    case list([BValue])
    case dict([String: BValue])
}

struct BencodeParser {
    let data: Data
    var index: Data.Index
    init(data: Data) { self.data = data; self.index = data.startIndex }
    mutating func parse() throws -> BValue {
        guard index < data.endIndex else { throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Torrent tidak lengkap."]) }
        let byte = data[index]
        switch byte {
        case UInt8(ascii: "i"):
            index += 1
            var end = index
            while end < data.endIndex && data[end] != UInt8(ascii: "e") { end += 1 }
            guard end < data.endIndex, let str = String(data: data[index..<end], encoding: .utf8), let v = Int64(str) else { throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Bilangan bencode rusak."]) }
            index = data.index(after: end)
            return .int(v)
        case UInt8(ascii: "l"):
            index += 1
            var items: [BValue] = []
            while data[index] != UInt8(ascii: "e") { items.append(try parse()) }
            index += 1
            return .list(items)
        case UInt8(ascii: "d"):
            index += 1
            var dict: [String: BValue] = [:]
            while data[index] != UInt8(ascii: "e") {
                let key = try parse()
                guard case .bytes(let kb) = key, let ks = String(data: kb, encoding: .utf8) else { throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Kunci bencode rusak."]) }
                dict[ks] = try parse()
            }
            index += 1
            return .dict(dict)
        default:
            guard byte >= 48 && byte <= 57 else { throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Bencode tidak dikenali."]) }
            var end = index
            while end < data.endIndex && data[end] != UInt8(ascii: ":") { end += 1 }
            guard end < data.endIndex, let lenStr = String(data: data[index..<end], encoding: .utf8), let len = Int(lenStr) else { throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Panjang string bencode rusak."]) }
            let start = data.index(after: end)
            let stop = data.index(start, offsetBy: len, limitedBy: data.endIndex) ?? data.endIndex
            let slice = data[start..<stop]
            index = stop
            return .bytes(Data(slice))
        }
    }
}

struct TorrentFileEntry: Identifiable {
    var id = UUID()
    var path: String
    var length: Int64
    var selected: Bool = true
}

struct TorrentInfo {
    var name: String
    var announce: String
    var announceList: [String]
    var infoHash: Data
    var pieceLength: Int64
    var pieces: [Data] // 20-byte SHA1 each
    var totalLength: Int64
    var files: [TorrentFileEntry]
    var isSingleFile: Bool
    var comment: String?
}

enum TorrentClient {
    static func parseTorrent(data: Data) throws -> TorrentInfo {
        // Find the raw "4:info" dict slice so the info-hash is over the exact bytes.
        guard let infoRange = findInfoDict(in: data) else { throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Info dict tidak ditemukan."]) }
        let infoBytes = data[infoRange]
        let infoHash = Data(Insecure.SHA1.hash(data: infoBytes))
        var parser = BencodeParser(data: data)
        let top = try parser.parse()
        guard case .dict(let root) = top, case .dict(let info) = root["info"] else { throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Struktur .torrent rusak."]) }
        func str(_ v: BValue?) -> String? { guard case .bytes(let d) = v else { return nil }; return String(data: d, encoding: .utf8) }
        func int(_ v: BValue?) -> Int64? { guard case .int(let i) = v else { return nil }; return i }
        let name = str(info["name"]) ?? "torrent"
        let pieceLength = int(info["piece length"]) ?? 262144
        var pieces: [Data] = []
        if case .bytes(let pd) = info["pieces"] {
            for off in stride(from: 0, to: pd.count, by: 20) { pieces.append(pd.subdata(in: off..<min(off + 20, pd.count))) }
        }
        var files: [TorrentFileEntry] = []
        var total: Int64 = 0
        if let len = int(info["length"]) {
            total = len; files = [TorrentFileEntry(path: name, length: len)]
        } else if case .list(let fl) = info["files"] {
            for f in fl {
                guard case .dict(let fd) = f, let len = int(fd["length"]), case .list(let pathParts) = fd["path"] else { continue }
                let path = pathParts.compactMap { str($0) }.joined(separator: "/")
                files.append(TorrentFileEntry(path: path, length: len))
                total += len
            }
        }
        var announceList: [String] = []
        if case .list(let tiers) = root["announce-list"] {
            for tier in tiers { if case .list(let urls) = tier { announceList += urls.compactMap { str($0) } } }
        }
        return TorrentInfo(name: name, announce: str(root["announce"]) ?? "", announceList: announceList, infoHash: infoHash, pieceLength: pieceLength, pieces: pieces, totalLength: total, files: files, isSingleFile: files.count <= 1, comment: str(root["comment"]))
    }

    private static func findInfoDict(in data: Data) -> Range<Data.Index>? {
        // Search for the key "4:info" then parse one bencode value starting right after it.
        let needle = Data("4:info".utf8)
        var searchFrom = data.startIndex
        while searchFrom < data.endIndex {
            guard let found = data.range(of: needle, in: searchFrom..<data.endIndex) else { return nil }
            var parser = BencodeParser(data: data)
            parser.index = found.upperBound
            let start = parser.index
            _ = try? parser.parse()
            // Re-parse to know the end: parse() advances index past the value.
            var p2 = BencodeParser(data: data); p2.index = start
            if (try? p2.parse()) != nil { return start..<p2.index }
            searchFrom = found.upperBound
        }
        return nil
    }

    static func parseMagnet(_ magnet: String) -> (infoHash: Data, name: String?, trackers: [String])? {
        guard let comps = URLComponents(string: magnet), comps.scheme == "magnet" else { return nil }
        var hashHex: String?
        var name: String?
        var trackers: [String] = []
        for item in comps.queryItems ?? [] {
            if item.name == "xt", let v = item.value, v.hasPrefix("urn:btih:") { hashHex = String(v.dropFirst("urn:btih:".count)) }
            if item.name == "dn" { name = item.value }
            if item.name == "tr", let v = item.value { trackers.append(v) }
        }
        guard let hex = hashHex else { return nil }
        if hex.count == 40, let data = Data(hexString: hex) { return (data, name, trackers) }
        if let data = Data(base32Encoded: hex) { return (data, name, trackers) }
        return nil
    }

    struct Peer: Hashable { var host: String; var port: UInt16 }

    static func announce(info: TorrentInfo, peerID: Data, port: UInt16, uploaded: Int64 = 0, downloaded: Int64 = 0, left: Int64) async throws -> [Peer] {
        let trackers = ([info.announce] + info.announceList).filter { $0.hasPrefix("http") }
        guard let tracker = trackers.first, var comps = URLComponents(string: tracker) else {
            throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Tidak ada tracker HTTP. Tracker UDP tidak didukung di port iOS ini."])
        }
        let hashEscaped = info.infoHash.map { String(format: "%%%02X", $0) }.joined()
        let peerEscaped = peerID.map { String(format: "%%%02X", $0) }.joined()
        comps.percentEncodedQuery = "info_hash=\(hashEscaped)&peer_id=\(peerEscaped)&port=\(port)&uploaded=\(uploaded)&downloaded=\(downloaded)&left=\(left)&compact=1&event=started"
        guard let url = comps.url else { throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "URL tracker rusak."]) }
        let (data, _) = try await URLSession.shared.data(from: url)
        var parser = BencodeParser(data: data)
        let resp = try parser.parse()
        guard case .dict(let dict) = resp else { throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Respons tracker rusak."]) }
        if case .bytes(let failure) = dict["failure reason"], let msg = String(data: failure, encoding: .utf8) {
            throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Tracker: \(msg)"])
        }
        var peers: [Peer] = []
        if case .bytes(let compact) = dict["peers"] {
            for off in stride(from: 0, to: compact.count, by: 6) {
                guard off + 6 <= compact.count else { break }
                let ip = compact[off..<off + 4].map { String($0) }.joined(separator: ".")
                let port = UInt16(compact[off + 4]) << 8 | UInt16(compact[off + 5])
                peers.append(Peer(host: ip, port: port))
            }
        } else if case .list(let list) = dict["peers"] {
            for p in list {
                guard case .dict(let pd) = p,
                      case .bytes(let ipData) = pd["ip"], let ip = String(data: ipData, encoding: .utf8),
                      case .int(let port) = pd["port"] else { continue }
                peers.append(Peer(host: ip, port: UInt16(port)))
            }
        }
        return peers
    }
}

extension Data {
    init?(hexString: String) {
        var hex = hexString
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        while !hex.isEmpty {
            let byteStr = hex.prefix(2); hex = String(hex.dropFirst(2))
            guard let byte = UInt8(byteStr, radix: 16) else { return nil }
            data.append(byte)
        }
        self = data
    }
    init?(base32Encoded: String) {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var bits = 0, value = 0
        var data = Data()
        for ch in base32Encoded.uppercased() {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | alphabet.distance(from: alphabet.startIndex, to: idx)
            bits += 5
            if bits >= 8 { data.append(UInt8((value >> (bits - 8)) & 0xFF)); bits -= 8 }
        }
        self = data
    }
}
