import Foundation
import Network
import CryptoKit

/// One peer connection, BitTorrent wire protocol (BEP 3), sequential pieces.
/// Keep-alive / extended protocol / fast extension are not implemented;
/// a peer that requires them will simply not serve pieces, and the caller
/// moves on to the next peer.
final class TorrentPeerSession {
    private let peer: TorrentClient.Peer
    private let info: TorrentInfo
    private let peerID: Data
    private var connection: NWConnection?
    private var buffer = Data()
    private var handshakeDone = false
    private var handshakeContinuation: CheckedContinuation<Void, Error>?
    private var unchokeContinuation: CheckedContinuation<Void, Error>?
    private var pieceContinuation: CheckedContinuation<Data, Error>?
    private var pieceBuffer = Data()
    private var pieceExpected = 0
    private var isChoked = true
    private(set) var availablePieces = Set<Int>()

    init(peer: TorrentClient.Peer, info: TorrentInfo, peerID: Data) {
        self.peer = peer; self.info = info; self.peerID = peerID
    }

    func connect() async throws {
        let host = NWEndpoint.Host(peer.host)
        guard let port = NWEndpoint.Port(rawValue: peer.port) else { throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Port peer rusak."]) }
        let conn = NWConnection(host: host, port: port, using: .tcp)
        self.connection = conn
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let err):
                    if !resumed { resumed = true; cont.resume(throwing: err) }
                case .cancelled:
                    if !resumed { resumed = true; cont.resume(throwing: NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Koneksi peer dibatalkan."])) }
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        // Handshake
        var hs = Data()
        hs.append(19)
        hs.append(contentsOf: "BitTorrent protocol".utf8)
        hs.append(Data(repeating: 0, count: 8))
        hs.append(info.infoHash)
        hs.append(peerID)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.handshakeContinuation = cont
            conn.send(content: hs, completion: .contentProcessed { _ in })
        }
        startReceiving()
        // Interested
        sendMessage(id: 2, payload: Data())
    }

    func disconnect() { connection?.cancel() }

    private func startReceiving() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if isComplete || error != nil {
                self.handshakeContinuation?.resume(throwing: NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Peer menutup koneksi."]))
                self.handshakeContinuation = nil
                self.pieceContinuation?.resume(throwing: NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Peer menutup koneksi."]))
                self.pieceContinuation = nil
                return
            }
            self.startReceiving()
        }
    }

    private func drainBuffer() {
        if !handshakeDone {
            guard buffer.count >= 68 else { return }
            let hs = buffer.prefix(68)
            buffer.removeFirst(68)
            // Validate info hash echoed back (bytes 28..<48).
            guard hs.count == 68, hs.subdata(in: 28..<48) == info.infoHash else {
                handshakeContinuation?.resume(throwing: NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Peer menolak info-hash."]))
                handshakeContinuation = nil
                return
            }
            handshakeDone = true
            handshakeContinuation?.resume()
            handshakeContinuation = nil
        }
        while buffer.count >= 4 {
            let len = Int(buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            if len == 0 { buffer.removeFirst(4); continue } // keep-alive
            guard buffer.count >= 4 + len else { return }
            let payload = buffer.subdata(in: 4..<(4 + len))
            buffer.removeFirst(4 + len)
            handleMessage(payload)
        }
    }

    private func handleMessage(_ payload: Data) {
        guard let id = payload.first else { return }
        let body = payload.dropFirst()
        switch id {
        case 0: // choke
            isChoked = true
        case 1: // unchoke
            isChoked = false
            unchokeContinuation?.resume(); unchokeContinuation = nil
        case 4: // have
            if body.count >= 4 {
                let idx = Int(body.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
                availablePieces.insert(idx)
            }
        case 5: // bitfield
            for (byteIdx, byte) in body.enumerated() {
                for bit in 0..<8 {
                    if (byte >> (7 - bit)) & 1 == 1 { availablePieces.insert(byteIdx * 8 + bit) }
                }
            }
        case 7: // piece: index(4) + begin(4) + block
            guard body.count > 8 else { return }
            pieceBuffer.append(body.dropFirst(8))
            if pieceBuffer.count >= pieceExpected {
                let data = Data(pieceBuffer.prefix(pieceExpected))
                pieceBuffer.removeAll()
                pieceContinuation?.resume(returning: data)
                pieceContinuation = nil
            }
        default: break
        }
    }

    private func sendMessage(id: UInt8, payload: Data) {
        var msg = Data()
        var len = UInt32(payload.count + 1).bigEndian
        msg.append(Data(bytes: &len, count: 4))
        msg.append(id)
        msg.append(payload)
        connection?.send(content: msg, completion: .contentProcessed { _ in })
    }

    func waitForUnchoke() async throws {
        if !isChoked { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.unchokeContinuation = cont
            // Re-assert interest in case the peer missed it.
            self.sendMessage(id: 2, payload: Data())
        }
    }

    func downloadPiece(index: Int, length: Int) async throws -> Data {
        try await waitForUnchoke()
        var result = Data()
        var offset = 0
        while offset < length {
            let blockLen = min(16384, length - offset)
            var payload = Data()
            var idx = UInt32(index).bigEndian; payload.append(Data(bytes: &idx, count: 4))
            var beg = UInt32(offset).bigEndian; payload.append(Data(bytes: &beg, count: 4))
            var ln = UInt32(blockLen).bigEndian; payload.append(Data(bytes: &ln, count: 4))
            let block: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.pieceExpected = blockLen
                self.pieceBuffer.removeAll()
                self.pieceContinuation = cont
                self.sendMessage(id: 6, payload: payload)
            }
            result.append(block)
            offset += block.count
            if block.count < blockLen { break }
        }
        return result
    }

    static func downloadTorrent(info: TorrentInfo, destination: URL, onProgress: ((Double) -> Void)?) async throws {
        var peerID = Data("MDM-IOS-".utf8)
        peerID.append(Data((0..<12).map { _ in UInt8.random(in: 0...9) + 48 }))
        let left = info.totalLength
        let peers = try await TorrentClient.announce(info: info, peerID: peerID, port: 6881, left: left)
        guard !peers.isEmpty else { throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Tracker tidak mengembalikan peer."]) }
        // Single-file only for the actual bytes; multi-file torrents are listed in UI.
        guard info.isSingleFile else { throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Torrent multi-file belum didukung di port iOS ini (baru metadata + daftar file)."]) }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        var lastError: Error?
        var completedPieces = 0
        for peer in peers.prefix(6) {
            let session = TorrentPeerSession(peer: peer, info: info, peerID: peerID)
            do {
                try await session.connect()
            } catch { lastError = error; continue }
            var failed = false
            for pieceIndex in completedPieces..<info.pieces.count {
                let isLast = pieceIndex == info.pieces.count - 1
                let pieceLen: Int
                if isLast {
                    let rem = info.totalLength - Int64(pieceIndex) * info.pieceLength
                    pieceLen = Int(max(0, rem))
                } else { pieceLen = Int(info.pieceLength) }
                do {
                    let data = try await session.downloadPiece(index: pieceIndex, length: pieceLen)
                    let hash = Data(Insecure.SHA1.hash(data: data))
                    guard hash == info.pieces[pieceIndex] else { throw NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Piece \(pieceIndex) gagal verifikasi SHA1."]) }
                    try handle.seek(toOffset: UInt64(Int64(pieceIndex) * info.pieceLength))
                    try handle.write(contentsOf: data)
                    completedPieces += 1
                    onProgress?(Double(completedPieces) / Double(max(1, info.pieces.count)))
                } catch {
                    lastError = error; failed = true; break
                }
            }
            session.disconnect()
            if !failed { break }
            if completedPieces >= info.pieces.count { break }
        }
        try? handle.close()
        if completedPieces < info.pieces.count {
            throw lastError ?? NSError(domain: "MDMTorrent", code: 0, userInfo: [NSLocalizedDescriptionKey: "Semua peer gagal sebelum torrent selesai."])
        }
    }
}
