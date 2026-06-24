//  DirStream.swift
//  Encode / decode of the IPMSG_GETDIRFILES streamed directory format:
//
//      HHHH:filename:sizeHex:attrHex[:extKeyHex=valHex...]:  <content bytes>
//
//  HHHH is the 4-hex-digit total byte length of the header (from the first
//  digit up to and including the ':' just before the content). A directory is
//  marked IPMSG_FILE_DIR and is closed by an IPMSG_FILE_RETPARENT entry whose
//  filename is ".". Mirrors MakeDirHeader / DecodeDirEntry in the Win32 source.

import Foundation

public struct DirEntry {
    public var name: String
    public var size: UInt64
    public var attr: UInt32
    public var mtime: UInt32
    public var ctime: UInt32

    public var mode: UInt32 { Command.mode(attr) }
    public var isDir: Bool { mode == FileType.DIR }
    public var isRetParent: Bool { mode == FileType.RETPARENT }
    public var isRegular: Bool { mode == FileType.REGULAR }

    public init(name: String, size: UInt64, attr: UInt32, mtime: UInt32 = 0, ctime: UInt32 = 0) {
        self.name = name
        self.size = size
        self.attr = attr
        self.mtime = mtime
        self.ctime = ctime
    }
}

public enum DirStream {

    /// Build one stream header. The ':' in names is replaced with ';' for safety.
    public static func encodeHeader(_ e: DirEntry) -> Data {
        let safeName = e.name.replacingOccurrences(of: ":", with: ";")
        var body = "0000:\(safeName):\(String(e.size, radix: 16)):\(String(e.attr, radix: 16)):"
        if e.mtime != 0 || e.ctime != 0 {
            body += "\(String(FileExt.MTIME, radix: 16))=\(String(e.mtime, radix: 16)):"
            body += "\(String(FileExt.CREATETIME, radix: 16))=\(String(e.ctime, radix: 16)):"
        }
        var bytes = Array(body.utf8)
        // Overwrite the leading "0000" placeholder with the real header length.
        let len = bytes.count
        let lenHex = String(format: "%04x", len)
        let lh = Array(lenHex.utf8)
        for i in 0..<4 { bytes[i] = lh[i] }
        return Data(bytes)
    }

    /// Parse a complete header (the `HHHH` length-prefixed bytes, content excluded).
    public static func decodeHeader(_ data: Data) -> DirEntry? {
        guard var s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS)
        else { return nil }
        s = s.replacingOccurrences(of: "::", with: ";")  // matches ConvertShareMsgEscape
        let f = s.components(separatedBy: ":")
        // [0]=HHHH [1]=name [2]=size [3]=attr [4..]=key=val ... trailing ""
        guard f.count >= 4 else { return nil }
        let name = f[1]
        guard let size = UInt64(f[2], radix: 16),
              let attr = UInt32(f[3], radix: 16) else { return nil }

        var mtime: UInt32 = 0, ctime: UInt32 = 0
        for i in 4..<f.count {
            let kv = f[i].components(separatedBy: "=")
            guard kv.count == 2, let key = UInt32(kv[0], radix: 16),
                  let val = UInt32(kv[1], radix: 16) else { continue }
            switch key {
            case FileExt.MTIME: mtime = val
            case FileExt.CREATETIME: ctime = val
            default: break
            }
        }
        return DirEntry(name: name, size: size, attr: attr, mtime: mtime, ctime: ctime)
    }

    /// Read the header length encoded in the first 4 bytes ("HHHH").
    public static func headerLength(prefix: Data) -> Int? {
        guard prefix.count >= 4,
              let s = String(data: prefix.prefix(4), encoding: .utf8),
              let n = Int(s, radix: 16) else { return nil }
        return n
    }
}
