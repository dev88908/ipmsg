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

            // body = packetID:fileID[:offset]  (all hex)
            let parts = pkt.body.split(separator: ":").map(String.init)
            guard parts.count >= 2,
                  let pktID = UInt32(parts[0], radix: 16),
                  let fileID = UInt32(parts[1], radix: 16),
                  let url = self.lookup(packetNo: pktID, fileID: fileID)
            else { conn.cancel(); return }

            switch pkt.commandMode {
            case Command.GETFILEDATA:
                let offset = parts.count >= 3 ? (UInt64(parts[2], radix: 16) ?? 0) : 0
                self.stream(url: url, offset: offset, over: conn)
            case Command.GETDIRFILES:
                self.streamDirectory(root: url, over: conn)
            default:
                conn.cancel()
            }
        }
    }

    // MARK: Directory tree streaming (IPMSG_GETDIRFILES)

    private enum DirItem {
        case header(Data)
        case content(URL)
    }

    /// Walk `root` once into an ordered list of headers + file references, then
    /// pump them sequentially. File contents are streamed from disk, never held
    /// in memory all at once.
    private func streamDirectory(root: URL, over conn: NWConnection) {
        var items: [DirItem] = []
        buildDirItems(root, isRoot: true, into: &items)
        pump(items, index: 0, over: conn)
    }

    private func buildDirItems(_ url: URL, isRoot: Bool, into items: inout [DirItem]) {
        let fm = FileManager.default
        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        let mtime = UInt32(((attrs[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0)
        let ctime = UInt32(((attrs[.creationDate] as? Date)?.timeIntervalSince1970) ?? 0)

        // Enter directory.
        items.append(.header(DirStream.encodeHeader(
            DirEntry(name: url.lastPathComponent, size: 0, attr: FileType.DIR,
                     mtime: mtime, ctime: ctime))))

        let children = (try? fm.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }) ?? []

        for child in children {
            let cattrs = (try? fm.attributesOfItem(atPath: child.path)) ?? [:]
            let isDir = (cattrs[.type] as? FileAttributeType) == .typeDirectory
            if isDir {
                buildDirItems(child, isRoot: false, into: &items)
            } else {
                let size = (cattrs[.size] as? NSNumber)?.uint64Value ?? 0
                let cmt = UInt32(((cattrs[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0)
                let cct = UInt32(((cattrs[.creationDate] as? Date)?.timeIntervalSince1970) ?? 0)
                items.append(.header(DirStream.encodeHeader(
                    DirEntry(name: child.lastPathComponent, size: size,
                             attr: FileType.REGULAR, mtime: cmt, ctime: cct))))
                if size > 0 { items.append(.content(child)) }
            }
        }

        // Leave directory (return to parent).
        items.append(.header(DirStream.encodeHeader(
            DirEntry(name: ".", size: 0, attr: FileType.RETPARENT, mtime: mtime, ctime: ctime))))
    }

    private func pump(_ items: [DirItem], index: Int, over conn: NWConnection) {
        guard index < items.count else {
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        switch items[index] {
        case .header(let data):
            conn.send(content: data, completion: .contentProcessed { [weak self] err in
                if err != nil { conn.cancel() } else { self?.pump(items, index: index + 1, over: conn) }
            })
        case .content(let url):
            streamFileContent(url: url, over: conn) { [weak self] ok in
                if ok { self?.pump(items, index: index + 1, over: conn) } else { conn.cancel() }
            }
        }
    }

    private func streamFileContent(url: URL, over conn: NWConnection, done: @escaping (Bool) -> Void) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { done(false); return }
        func step() {
            let chunk = (try? fh.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty { try? fh.close(); done(true); return }
            conn.send(content: chunk, completion: .contentProcessed { err in
                if err != nil { try? fh.close(); done(false) } else { step() }
            })
        }
        step()
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

// MARK: - Incoming: download a directory tree (IPMSG_GETDIRFILES).

public final class DirectoryReceiver: @unchecked Sendable {

    public struct Request {
        public var host: String
        public var port: UInt16
        public var packetNo: UInt32
        public var fileID: UInt32
        public var totalSize: UInt64       // for progress (0 if unknown)
        public var rootName: String        // name to give the top-level folder
        public var localUser: String
        public var localHost: String
        public var requestPacketNo: UInt32
    }

    private let req: Request
    private let destDir: URL
    private let progress: (UInt64, UInt64) -> Void
    private let completion: (Result<URL, Error>) -> Void

    private var conn: NWConnection!
    private var buffer = Data()
    private var stack: [URL] = []          // current directory path
    private var rootURL: URL?
    private var pending: (handle: FileHandle, remaining: UInt64)?
    private var written: UInt64 = 0
    private var finished = false
    private var selfRef: DirectoryReceiver?   // keep alive for the async lifetime

    private init(_ req: Request, to destDir: URL,
                 progress: @escaping (UInt64, UInt64) -> Void,
                 completion: @escaping (Result<URL, Error>) -> Void) {
        self.req = req
        self.destDir = destDir
        self.progress = progress
        self.completion = completion
    }

    public static func download(
        _ req: Request, to destDir: URL,
        progress: @escaping (UInt64, UInt64) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let r = DirectoryReceiver(req, to: destDir, progress: progress, completion: completion)
        r.start()
    }

    private func start() {
        selfRef = self
        conn = NWConnection(host: NWEndpoint.Host(req.host),
                            port: NWEndpoint.Port(rawValue: req.port)!, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let body = String(format: "%x:%x:", self.req.packetNo, self.req.fileID)
                let pkt = PacketCodec.encode(
                    packetNo: self.req.requestPacketNo,
                    userName: self.req.localUser, hostName: self.req.localHost,
                    command: Command.GETDIRFILES, body: body)
                self.conn.send(content: pkt, completion: .contentProcessed { err in
                    if let err { self.finish(.failure(err)) } else { self.readLoop() }
                })
            case .failed(let e):
                self.finish(.failure(e))
            default:
                break
            }
        }
        conn.start(queue: .global())
    }

    private func readLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if !self.consume() { return }   // consume() calls finish() on error/done
            }
            if let error { self.finish(.failure(error)); return }
            if self.finished { return }
            if isComplete {
                self.finish(self.stack.isEmpty && self.rootURL != nil
                    ? .success(self.rootURL!)
                    : .failure(ftError("connection closed mid-tree")))
                return
            }
            self.readLoop()
        }
    }

    /// Drain the buffer; returns false once the transfer is complete/failed.
    private func consume() -> Bool {
        while true {
            // Mid-file: write content bytes first.
            if var p = pending {
                let take = Int(min(p.remaining, UInt64(buffer.count)))
                if take == 0 { return true }                // need more data
                let chunk = buffer.prefix(take)
                p.handle.write(chunk)
                buffer.removeFirst(take)
                written += UInt64(take)
                progress(written, req.totalSize)
                p.remaining -= UInt64(take)
                if p.remaining == 0 { try? p.handle.close(); pending = nil }
                else { pending = p; return true }
                continue
            }

            // Need a header: first the 4-hex length, then the full header.
            guard buffer.count >= 5, let hlen = DirStream.headerLength(prefix: buffer) else {
                if buffer.count >= 5 { finish(.failure(ftError("bad dir header"))); return false }
                return true
            }
            guard buffer.count >= hlen else { return true }   // wait for full header
            let headerData = buffer.prefix(hlen)
            buffer.removeFirst(hlen)

            guard let entry = DirStream.decodeHeader(headerData) else {
                finish(.failure(ftError("undecodable dir entry"))); return false
            }
            if !handle(entry) { return false }
            if finished { return false }
        }
    }

    /// Apply one decoded entry to the on-disk tree. Returns false on fatal error.
    private func handle(_ entry: DirEntry) -> Bool {
        let fm = FileManager.default

        if entry.isDir {
            // First DIR entry is the root; use the attachment's name for it.
            let name = stack.isEmpty ? req.rootName : safeComponent(entry.name)
            guard let safe = name else { finish(.failure(ftError("unsafe path"))); return false }
            let dir = (stack.last ?? destDir).appendingPathComponent(safe)
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { finish(.failure(error)); return false }
            if rootURL == nil { rootURL = dir }
            stack.append(dir)
            return true
        }

        if entry.isRetParent {
            if let dir = stack.popLast(), entry.mtime != 0 {
                try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(entry.mtime))],
                                      ofItemAtPath: dir.path)
            }
            if stack.isEmpty {
                finish(.success(rootURL ?? destDir))   // tree complete
                return false
            }
            return true
        }

        // Regular file inside the current directory.
        guard let parent = stack.last, let comp = safeComponent(entry.name) else {
            finish(.failure(ftError("file outside directory"))); return false
        }
        let fileURL = parent.appendingPathComponent(comp)
        fm.createFile(atPath: fileURL.path, contents: nil)
        if entry.size == 0 { return true }
        guard let fh = try? FileHandle(forWritingTo: fileURL) else {
            finish(.failure(ftError("cannot create \(comp)"))); return false
        }
        pending = (fh, entry.size)
        return true
    }

    /// Reject path-traversal / separators (mirrors IsSafePath in the Win32 code).
    private func safeComponent(_ name: String) -> String? {
        if name.isEmpty || name == "." || name == ".." { return nil }
        if name.contains("/") || name.contains("\\") || name.contains("..") { return nil }
        return name
    }

    private func finish(_ result: Result<URL, Error>) {
        if finished { return }
        finished = true
        if let p = pending { try? p.handle.close(); pending = nil }
        conn.cancel()
        completion(result)
        selfRef = nil   // release after completion
    }
}

private func ftError(_ msg: String) -> NSError {
    NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
}
