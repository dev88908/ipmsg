//  Models.swift
//  Observable data types shared between the engine and the SwiftUI layer.

import Foundation

/// A discovered peer on the LAN (Windows IP Messenger or another client).
public struct Peer: Identifiable, Hashable, Sendable {
    public var userName: String
    public var hostName: String
    public var nickName: String
    public var groupName: String
    public var address: String   // dotted IPv4 / IPv6 literal
    public var port: UInt16
    public var lastSeen: Date
    public var inAbsence: Bool

    /// Stable identity matches the Win32 client: userName + hostName.
    public var id: String { "\(userName)@\(hostName)" }

    public var displayName: String {
        nickName.isEmpty ? userName : nickName
    }

    public init(userName: String, hostName: String, nickName: String = "",
                groupName: String = "", address: String, port: UInt16,
                lastSeen: Date = Date(), inAbsence: Bool = false) {
        self.userName = userName
        self.hostName = hostName
        self.nickName = nickName
        self.groupName = groupName
        self.address = address
        self.port = port
        self.lastSeen = lastSeen
        self.inAbsence = inAbsence
    }
}

/// A file offered inside an inbound message (download not yet started).
public struct AttachedFile: Identifiable, Hashable, Sendable {
    public var id: UInt32          // fileID from the sender
    public var name: String
    public var size: UInt64
    public var mtime: UInt32
    public var attr: UInt32
    public var isDir: Bool { Command.mode(attr) == FileType.DIR }

    public init(id: UInt32, name: String, size: UInt64, mtime: UInt32, attr: UInt32) {
        self.id = id
        self.name = name
        self.size = size
        self.mtime = mtime
        self.attr = attr
    }
}

public enum DownloadState: Equatable, Sendable {
    case idle
    case downloading(received: UInt64, total: UInt64)
    case done(url: URL)
    case failed(String)
}

/// One line in a conversation.
public struct ChatMessage: Identifiable, Sendable {
    public enum Direction: Sendable { case incoming, outgoing, system }

    public let id = UUID()
    public var direction: Direction
    public var peerID: String
    public var text: String
    public var date: Date
    public var packetNo: UInt32
    public var attachments: [AttachedFile]
    public var delivered: Bool        // outgoing: RECVMSG acked
    public var senderAddress: String  // incoming: where to pull files from
    public var senderPort: UInt16

    public init(direction: Direction, peerID: String, text: String,
                date: Date = Date(), packetNo: UInt32 = 0,
                attachments: [AttachedFile] = [], delivered: Bool = false,
                senderAddress: String = "", senderPort: UInt16 = 0) {
        self.direction = direction
        self.peerID = peerID
        self.text = text
        self.date = date
        self.packetNo = packetNo
        self.attachments = attachments
        self.delivered = delivered
        self.senderAddress = senderAddress
        self.senderPort = senderPort
    }
}

/// Local identity advertised to the LAN.
public struct LocalIdentity: Sendable {
    public var userName: String
    public var hostName: String
    public var nickName: String
    public var groupName: String

    public init(userName: String, hostName: String, nickName: String, groupName: String = "") {
        self.userName = userName
        self.hostName = hostName
        self.nickName = nickName
        self.groupName = groupName
    }

    public static func current(nickName: String? = nil) -> LocalIdentity {
        let user = NSUserName()
        var host = ProcessInfo.processInfo.hostName
        // Trim the trailing ".local" Bonjour suffix for cleaner display.
        if host.hasSuffix(".local") { host = String(host.dropLast(6)) }
        return LocalIdentity(
            userName: user,
            hostName: host,
            nickName: nickName ?? user
        )
    }
}
