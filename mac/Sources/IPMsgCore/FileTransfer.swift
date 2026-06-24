//  FileTransfer.swift
//  TCP side of the protocol. Files are pulled by the receiver:
//   * FileServer answers IPMSG_GETFILEDATA by streaming raw file bytes.
//   * FileDownloader connects to a sender and pulls one attached file.
//
//  Regular files are fully supported in both directions. Directory trees
//  (IPMSG_GETDIRFILES) are not yet implemented.

import Foundation
import Network

// MARK: - Outgoing: serve files that we attached to a SENDMSG.

public final class FileServer: @unchecked Sendable {
    /// fileID -> local file URL, grouped by the attach packet number.
    private var offers: [UInt32: [UInt32: URL]] = [:]
    private let lock = NSLock()
    private var listener: NWListener?
    private let port: UInt16

    public init(port: UInt16) { self.port = port }

    public func register(packetNo: UInt32, files: [UInt32: URL]) {
        lock.lock(); offers[packetNo] = files; lock.unlock()
    }

    private func lookup(packetNo: UInt32, fileID: UInt32) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return offers[packetNo]?[fileID]
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: .global())
        listener = l
    }

    public func stop() { listener?.cancel(); listener = nil }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let pkt = PacketCodec.decode(data) else { conn.cancel(); return }
            guard pkt.commandMode == Command.GETFILEDATA else { conn.cancel(); return }

            // body = packetID:fileID:offset  (all hex)
            let parts = pkt.body.split(separator: ":").map(String.init)
            guard parts.count >= 2,
                  let pktID = UInt32(parts[0], radix: 16),
                  let fileID = UInt32(parts[1], radix: 16),
                  let url = self.lookup(packetNo: pktID, fileID: fileID)
            else { conn.cancel(); return }
            let offset = parts.count >= 3 ? (UInt64(parts[2], radix: 16) ?? 0) : 0

            self.stream(url: url, offset: offset, over: conn)
        }
    }

    private func stream(url: URL, offset: UInt64, over conn: NWConnection) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { conn.cancel(); return }
        if offset > 0 { try? fh.seek(toOffset: offset) }

        func pump() {
            let chunk = (try? fh.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty {
                try? fh.close()
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            conn.send(content: chunk, completion: .contentProcessed { error in
                if error != nil { try? fh.close(); conn.cancel() } else { pump() }
            })
        }
        pump()
    }
}

// MARK: - Incoming: download a file offered by a peer.

public final class FileDownloader: @unchecked Sendable {

    public struct Request {
        public var host: String
        public var port: UInt16
        public var packetNo: UInt32   // the attach packet number from the sender
        public var fileID: UInt32
        public var size: UInt64
        public var localUser: String
        public var localHost: String
        public var requestPacketNo: UInt32
    }

    /// Download `req` to `destination`, reporting progress and completion on `queue`.
    public static func download(
        _ req: Request,
        to destination: URL,
        progress: @escaping (UInt64, UInt64) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let conn = NWConnection(
            host: NWEndpoint.Host(req.host),
            port: NWEndpoint.Port(rawValue: req.port)!,
            using: .tcp)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: destination) else {
            completion(.failure(ftError("cannot open destination"))); return
        }

        var received: UInt64 = 0
        func finish(_ result: Result<URL, Error>) {
            try? fh.close()
            conn.cancel()
            completion(result)
        }

        func readLoop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    fh.write(data)
                    received += UInt64(data.count)
                    progress(received, req.size)
                }
                if let error { finish(.failure(error)); return }
                if received >= req.size && req.size > 0 { finish(.success(destination)); return }
                if isComplete {
                    if req.size == 0 || received >= req.size { finish(.success(destination)) }
                    else { finish(.failure(ftError("connection closed early (\(received)/\(req.size))"))) }
                    return
                }
                readLoop()
            }
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // body = packetID:fileID:offset (hex)
                let body = String(format: "%x:%x:0", req.packetNo, req.fileID)
                let pkt = PacketCodec.encode(
                    packetNo: req.requestPacketNo,
                    userName: req.localUser,
                    hostName: req.localHost,
                    command: Command.GETFILEDATA,
                    body: body)
                conn.send(content: pkt, completion: .contentProcessed { err in
                    if let err { finish(.failure(err)) } else { readLoop() }
                })
            case .failed(let e):
                finish(.failure(e))
            default:
                break
            }
        }
        conn.start(queue: .global())
    }
}

private func ftError(_ msg: String) -> NSError {
    NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
}
