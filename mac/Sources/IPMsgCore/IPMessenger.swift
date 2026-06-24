//  IPMessenger.swift
//  The engine: discovery, messaging and file transfer wired together and
//  exposed to SwiftUI as an ObservableObject.

import Foundation
import Combine

public final class IPMessenger: ObservableObject {

    // MARK: Published state (mutated on the main thread).
    @Published public private(set) var peers: [Peer] = []
    @Published public private(set) var messagesByPeer: [String: [ChatMessage]] = [:]
    @Published public private(set) var downloads: [UInt32: DownloadState] = [:]  // keyed by fileID
    @Published public var identity: LocalIdentity

    public var downloadDirectory: URL =
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())

    private let port: UInt16
    private let udp: UDPSocket
    private let fileServer: FileServer
    private var packetCounter: UInt32

    public init(nickName: String? = nil, port: UInt16 = IPMSG_DEFAULT_PORT) {
        self.port = port
        self.identity = LocalIdentity.current(nickName: nickName)
        self.udp = UDPSocket(port: port)
        self.fileServer = FileServer(port: port)
        self.packetCounter = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
    }

    // MARK: Lifecycle

    public func start() throws {
        udp.onReceive = { [weak self] data, ip, srcPort in
            guard let self, let pkt = PacketCodec.decode(data) else { return }
            DispatchQueue.main.async { self.dispatch(pkt, from: ip, srcPort: srcPort) }
        }
        try udp.start()
        try? fileServer.start()
        announceEntry()
    }

    public func stop() {
        broadcast(command: Command.BR_EXIT, body: identity.nickName,
                  extra: identity.groupName, withExtBlock: true)
        udp.close()
        fileServer.stop()
    }

    private func nextPacketNo() -> UInt32 {
        packetCounter &+= 1
        return packetCounter
    }

    private var isSelf: (String, String) -> Bool {
        { [id = identity] user, host in user == id.userName && host == id.hostName }
    }

    // MARK: Discovery

    /// Broadcast BR_ENTRY so existing members add us and answer back.
    public func announceEntry() {
        broadcast(command: Command.BR_ENTRY, body: identity.nickName,
                  extra: identity.groupName, withExtBlock: true)
    }

    private func extBlockString() -> String {
        let vs = String(format: "%08x:macOS IPMsg", IPMSG_VER_MAC_TYPE)
        return "\nUN:\(identity.userName)\nHN:\(identity.hostName)" +
               "\nNN:\(identity.nickName)\nGN:\(identity.groupName)\nVS:\(vs)"
    }

    private func broadcast(command: UInt32, body: String, extra: String?, withExtBlock: Bool) {
        let cmd = command | Opt.CAPUTF8 | Opt.FILEATTACH
        let data = PacketCodec.encode(
            packetNo: nextPacketNo(),
            userName: identity.userName, hostName: identity.hostName,
            command: cmd, body: body, extra: extra,
            extBlock: withExtBlock ? extBlockString() : nil)
        udp.broadcast(data, port: port)
    }

    // MARK: Sending messages

    /// Send a text message (and optionally files) to a peer.
    public func send(text: String, to peer: Peer, files: [URL] = []) {
        let packetNo = nextPacketNo()
        var command = Command.SENDMSG | Opt.UTF8 | Opt.SENDCHECK
        var fileListStr: String? = nil
        var attachments: [AttachedFile] = []

        if !files.isEmpty {
            let (listStr, offers, atts) = buildFileList(files)
            if !offers.isEmpty {
                command |= Opt.FILEATTACH
                fileListStr = listStr
                fileServer.register(packetNo: packetNo, files: offers)
                attachments = atts
            }
        }

        let data = PacketCodec.encode(
            packetNo: packetNo,
            userName: identity.userName, hostName: identity.hostName,
            command: command, body: text, extra: fileListStr)
        udp.send(data, to: peer.address, port: peer.port)

        let msg = ChatMessage(direction: .outgoing, peerID: peer.id, text: text,
                              packetNo: packetNo, attachments: attachments)
        append(msg, to: peer.id)
    }

    /// Build the wire file list, the fileID->URL offer map, and UI attachments.
    private func buildFileList(_ files: [URL]) -> (String, [UInt32: URL], [AttachedFile]) {
        var list = ""
        var offers: [UInt32: URL] = [:]
        var atts: [AttachedFile] = []
        var fid = nextPacketNo() & 0x3fff_ffff

        for url in files {
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            if isDir { continue }  // directory trees not yet supported
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = UInt32(((attrs[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0)
            let attr = FileType.REGULAR
            let name = url.lastPathComponent.replacingOccurrences(of: ":", with: ";")

            list += "\(fid):\(name):\(String(size, radix: 16)):\(String(mtime, radix: 16)):\(String(attr, radix: 16)):"
            list.append(FILELIST_SEPARATOR)

            offers[fid] = url
            atts.append(AttachedFile(id: fid, name: url.lastPathComponent,
                                     size: size, mtime: mtime, attr: attr))
            fid &+= 1
        }
        return (list, offers, atts)
    }

    // MARK: Receiving

    private func dispatch(_ pkt: Packet, from ip: String, srcPort: UInt16) {
        if isSelf(pkt.userName, pkt.hostName) { return }  // ignore our own packets

        switch pkt.commandMode {
        case Command.BR_ENTRY:
            upsertPeer(pkt, ip: ip, port: srcPort)
            // Answer privately so the new member learns about us.
            sendAnswerEntry(to: ip, port: srcPort)

        case Command.ANSENTRY, Command.ANSLIST:
            upsertPeer(pkt, ip: ip, port: srcPort)

        case Command.BR_ABSENCE:
            upsertPeer(pkt, ip: ip, port: srcPort)

        case Command.BR_EXIT:
            removePeer(pkt)

        case Command.SENDMSG:
            handleSendMsg(pkt, ip: ip, srcPort: srcPort)

        case Command.RECVMSG, Command.ANSREADMSG:
            markDelivered(originalPacketNo: pkt.body, peerKey: "\(pkt.userName)@\(pkt.hostName)")

        case Command.READMSG, Command.NOOPERATION:
            break

        default:
            break
        }
    }

    private func sendAnswerEntry(to ip: String, port: UInt16) {
        let cmd = Command.ANSENTRY | Opt.CAPUTF8 | Opt.FILEATTACH
        let data = PacketCodec.encode(
            packetNo: nextPacketNo(),
            userName: identity.userName, hostName: identity.hostName,
            command: cmd, body: identity.nickName, extra: identity.groupName,
            extBlock: extBlockString())
        udp.send(data, to: ip, port: port)
    }

    private func handleSendMsg(_ pkt: Packet, ip: String, srcPort: UInt16) {
        // Acknowledge if the sender requested a delivery check.
        if pkt.hasOpt(Opt.SENDCHECK) {
            let ack = PacketCodec.encode(
                packetNo: nextPacketNo(),
                userName: identity.userName, hostName: identity.hostName,
                command: Command.RECVMSG | Opt.UTF8,
                body: String(pkt.packetNo))
            udp.send(ack, to: ip, port: srcPort)
        }

        var attachments: [AttachedFile] = []
        if pkt.hasOpt(Opt.FILEATTACH), pkt.segments.count > 1 {
            attachments = parseFileList(pkt.segments[1])
        }

        let peerKey = "\(pkt.userName)@\(pkt.hostName)"
        let msg = ChatMessage(direction: .incoming, peerID: peerKey, text: pkt.body,
                              packetNo: pkt.packetNo, attachments: attachments,
                              senderAddress: ip, senderPort: srcPort)
        append(msg, to: peerKey)

        // Make sure an unknown sender appears in the peer list.
        if !peers.contains(where: { $0.id == peerKey }) {
            upsertPeer(pkt, ip: ip, port: srcPort)
        }
    }

    private func parseFileList(_ list: String) -> [AttachedFile] {
        var result: [AttachedFile] = []
        for record in list.split(separator: FILELIST_SEPARATOR, omittingEmptySubsequences: true) {
            let f = record.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let id = UInt32(f[0]) else { continue }
            let name = f[1].replacingOccurrences(of: "::", with: ":")
            let size = UInt64(f[2], radix: 16) ?? 0
            let mtime = UInt32(f[3], radix: 16) ?? 0
            let attr = UInt32(f[4], radix: 16) ?? FileType.REGULAR
            result.append(AttachedFile(id: id, name: name, size: size, mtime: mtime, attr: attr))
        }
        return result
    }

    // MARK: Downloads

    /// Download an attachment from the message it arrived with.
    public func download(_ file: AttachedFile, from message: ChatMessage) {
        guard !file.isDir else {
            downloads[file.id] = .failed("directory download not supported")
            return
        }
        let dest = uniqueDestination(for: file.name)
        downloads[file.id] = .downloading(received: 0, total: file.size)

        let req = FileDownloader.Request(
            host: message.senderAddress, port: message.senderPort,
            packetNo: message.packetNo, fileID: file.id, size: file.size,
            localUser: identity.userName, localHost: identity.hostName,
            requestPacketNo: nextPacketNo())

        FileDownloader.download(req, to: dest, progress: { [weak self] got, total in
            DispatchQueue.main.async { self?.downloads[file.id] = .downloading(received: got, total: total) }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url): self?.downloads[file.id] = .done(url: url)
                case .failure(let e): self?.downloads[file.id] = .failed(e.localizedDescription)
                }
            }
        })
    }

    private func uniqueDestination(for name: String) -> URL {
        let fm = FileManager.default
        var url = downloadDirectory.appendingPathComponent(name)
        var i = 1
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while fm.fileExists(atPath: url.path) {
            let newName = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            url = downloadDirectory.appendingPathComponent(newName)
            i += 1
        }
        return url
    }

    // MARK: Peer / message bookkeeping

    private func upsertPeer(_ pkt: Packet, ip: String, port: UInt16) {
        let ext = pkt.extBlock
        let nick = ext["NN"] ?? (pkt.body.isEmpty ? pkt.userName : pkt.body)
        let group = ext["GN"] ?? (pkt.segments.count > 1 ? pkt.segments[1] : "")
        let absence = pkt.hasOpt(Opt.ABSENCE)
        let key = "\(pkt.userName)@\(pkt.hostName)"

        if let idx = peers.firstIndex(where: { $0.id == key }) {
            peers[idx].nickName = nick
            peers[idx].groupName = group
            peers[idx].address = ip
            peers[idx].port = port
            peers[idx].lastSeen = Date()
            peers[idx].inAbsence = absence
        } else {
            peers.append(Peer(userName: pkt.userName, hostName: pkt.hostName,
                              nickName: nick, groupName: group, address: ip,
                              port: port, inAbsence: absence))
            peers.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }

    private func removePeer(_ pkt: Packet) {
        let key = "\(pkt.userName)@\(pkt.hostName)"
        peers.removeAll { $0.id == key }
    }

    private func append(_ msg: ChatMessage, to peerKey: String) {
        messagesByPeer[peerKey, default: []].append(msg)
    }

    private func markDelivered(originalPacketNo: String, peerKey: String) {
        guard let no = UInt32(originalPacketNo.trimmingCharacters(in: .whitespaces)) else { return }
        guard var msgs = messagesByPeer[peerKey] else { return }
        if let idx = msgs.firstIndex(where: { $0.packetNo == no && $0.direction == .outgoing }) {
            msgs[idx].delivered = true
            messagesByPeer[peerKey] = msgs
        }
    }

    public func messages(for peerID: String) -> [ChatMessage] {
        messagesByPeer[peerID] ?? []
    }
}
