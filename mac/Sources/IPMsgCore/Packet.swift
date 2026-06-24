//  Packet.swift
//  Encode / decode of the classic IP Messenger "version-1" datagram:
//
//      ver : packetNo : userName : hostName : command : <additional>
//
//  The additional section is NUL-separated. For a plain message it is just the
//  body; for SENDMSG with attachments it is  body \0 fileList ; for entry/exit
//  broadcasts it is  nick \0 group \0 \nUN:..\nHN:..\nNN:..\nGN:..\nVS:..

import Foundation

/// A decoded inbound packet.
public struct Packet {
    public var version: Int
    public var packetNo: UInt32
    public var userName: String
    public var hostName: String
    public var command: UInt32

    /// NUL-separated segments of the additional section, decoded to text.
    public var segments: [String]
    /// Raw additional-section bytes (kept for binary/attach parsing).
    public var rawAdditional: [UInt8]

    public var commandMode: UInt32 { Command.mode(command) }
    public var commandOpt: UInt32 { Command.opt(command) }
    public func hasOpt(_ o: UInt32) -> Bool { (command & o) != 0 }

    /// Message body / first segment.
    public var body: String { segments.first ?? "" }

    /// Extended `\nKEY:value` block carried by entry/answer broadcasts.
    public var extBlock: [String: String] {
        // The block is whichever segment begins with a newline+KEY pattern.
        for seg in segments where seg.contains("\n") {
            var dict: [String: String] = [:]
            for line in seg.split(separator: "\n", omittingEmptySubsequences: true) {
                if let colon = line.firstIndex(of: ":") {
                    let key = String(line[..<colon])
                    let val = String(line[line.index(after: colon)...])
                    dict[key] = val
                }
            }
            if !dict.isEmpty { return dict }
        }
        return [:]
    }
}

public enum PacketCodec {

    /// Build an outbound datagram. The client always advertises/uses UTF-8.
    /// - Parameters:
    ///   - extra: second segment (group name for entry packets, file list for SENDMSG).
    ///   - extBlock: trailing `\nKEY:value` block (entry/answer packets only).
    public static func encode(
        version: Int = IPMSG_VERSION,
        packetNo: UInt32,
        userName: String,
        hostName: String,
        command: UInt32,
        body: String,
        extra: String? = nil,
        extBlock: String? = nil
    ) -> Data {
        var out = [UInt8]()
        let header = "\(version):\(packetNo):\(userName):\(hostName):\(command):"
        out.append(contentsOf: Array(header.utf8))
        out.append(contentsOf: Array(body.utf8))

        // First NUL separator always follows the body.
        out.append(0)
        if let extra { out.append(contentsOf: Array(extra.utf8)) }

        if let extBlock {
            out.append(0)
            out.append(contentsOf: Array(extBlock.utf8))
        }
        return Data(out)
    }

    /// Parse an inbound datagram. Returns nil if the 5 header fields are malformed.
    public static func decode(_ data: Data) -> Packet? {
        let bytes = [UInt8](data)
        // Locate the 5th ':' that ends the header. The additional section may
        // itself contain ':' so we must stop counting after field 5.
        var colon = 0
        var headerEnd = -1
        for (i, b) in bytes.enumerated() where b == UInt8(ascii: ":") {
            colon += 1
            if colon == 5 { headerEnd = i; break }
        }
        guard headerEnd >= 0 else { return nil }

        let headerBytes = Array(bytes[0..<headerEnd])
        guard let headerStr = String(bytes: headerBytes, encoding: .utf8) else { return nil }
        let f = headerStr.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 5,
              let ver = Int(f[0]),
              let pkt = UInt32(f[1]),
              let cmd = UInt32(f[4])
        else { return nil }

        let additional = Array(bytes[(headerEnd + 1)...])
        let useUTF8 = (cmd & Opt.UTF8) != 0
        let segments = splitNUL(additional).map { decodeText($0, utf8: useUTF8) }

        return Packet(
            version: ver,
            packetNo: pkt,
            userName: f[2],
            hostName: f[3],
            command: cmd,
            segments: segments,
            rawAdditional: additional
        )
    }

    /// Split bytes on NUL boundaries.
    static func splitNUL(_ bytes: [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var cur: [UInt8] = []
        for b in bytes {
            if b == 0 { result.append(cur); cur = [] } else { cur.append(b) }
        }
        result.append(cur)
        return result
    }

    /// Decode a text segment, falling back from UTF-8 to CP932 (≈ Shift_JIS).
    static func decodeText(_ bytes: [UInt8], utf8: Bool) -> String {
        let data = Data(bytes)
        if utf8, let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .shiftJIS) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}
