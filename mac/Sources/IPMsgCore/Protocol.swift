//  Protocol.swift
//  IP Messenger protocol constants (classic "version-1" wire format).
//
//  Values mirror src/ipmsg.h from the Windows reference implementation so this
//  client is byte-compatible with IP Messenger for Win32 on the LAN.

import Foundation

/// Default UDP (messages) / TCP (file transfer) port: 0x0979.
public let IPMSG_DEFAULT_PORT: UInt16 = 0x0979  // 2425

/// Protocol header version written as the first packet field ("1").
public let IPMSG_VERSION = 1

/// Command numbers occupy the low 8 bits; option flags the high 24 bits.
public enum Command {
    public static func mode(_ c: UInt32) -> UInt32 { c & 0x0000_00ff }
    public static func opt(_ c: UInt32) -> UInt32 { c & 0xffff_ff00 }

    // --- commands (low byte) ---
    public static let NOOPERATION: UInt32 = 0x0000_0000

    public static let BR_ENTRY: UInt32 = 0x0000_0001
    public static let BR_EXIT: UInt32 = 0x0000_0002
    public static let ANSENTRY: UInt32 = 0x0000_0003
    public static let BR_ABSENCE: UInt32 = 0x0000_0004

    public static let BR_ISGETLIST: UInt32 = 0x0000_0010
    public static let OKGETLIST: UInt32 = 0x0000_0011
    public static let GETLIST: UInt32 = 0x0000_0012
    public static let ANSLIST: UInt32 = 0x0000_0013

    public static let SENDMSG: UInt32 = 0x0000_0020
    public static let RECVMSG: UInt32 = 0x0000_0021
    public static let READMSG: UInt32 = 0x0000_0030
    public static let DELMSG: UInt32 = 0x0000_0031
    public static let ANSREADMSG: UInt32 = 0x0000_0032

    public static let GETINFO: UInt32 = 0x0000_0040
    public static let SENDINFO: UInt32 = 0x0000_0041

    public static let GETABSENCEINFO: UInt32 = 0x0000_0050
    public static let SENDABSENCEINFO: UInt32 = 0x0000_0051

    public static let GETFILEDATA: UInt32 = 0x0000_0060
    public static let RELEASEFILES: UInt32 = 0x0000_0061
    public static let GETDIRFILES: UInt32 = 0x0000_0062

    public static let GETPUBKEY: UInt32 = 0x0000_0072
    public static let ANSPUBKEY: UInt32 = 0x0000_0073
}

/// Option flags valid on any command (high 24 bits).
public enum Opt {
    public static let ABSENCE: UInt32 = 0x0000_0100
    public static let SERVER: UInt32 = 0x0000_0200
    public static let DIALUP: UInt32 = 0x0001_0000
    public static let FILEATTACH: UInt32 = 0x0020_0000
    public static let ENCRYPT: UInt32 = 0x0040_0000
    public static let UTF8: UInt32 = 0x0080_0000
    public static let CAPUTF8: UInt32 = 0x0100_0000
    public static let ENCEXTMSG: UInt32 = 0x0400_0000
    public static let CLIPBOARD: UInt32 = 0x0800_0000

    // SENDMSG-specific options (reuse the same high-bit space).
    public static let SENDCHECK: UInt32 = 0x0000_0100
    public static let SECRET: UInt32 = 0x0000_0200
    public static let BROADCAST: UInt32 = 0x0000_0400
    public static let MULTICAST: UInt32 = 0x0000_0800
    public static let AUTORET: UInt32 = 0x0000_2000
    public static let RETRY: UInt32 = 0x0000_4000
    public static let PASSWORD: UInt32 = 0x0000_8000
    public static let NOLOG: UInt32 = 0x0002_0000
    public static let NOADDLIST: UInt32 = 0x0008_0000
    public static let READCHECK: UInt32 = 0x0010_0000
}

/// File entry attribute types (low byte of fileattr).
public enum FileType {
    public static let REGULAR: UInt32 = 0x0000_0001
    public static let DIR: UInt32 = 0x0000_0002
    public static let RETPARENT: UInt32 = 0x0000_0003
    public static let SYMLINK: UInt32 = 0x0000_0004
    public static let CLIPBOARD: UInt32 = 0x0000_0020
}

/// Extended file-attribute keys used inside dir-stream headers (`key=val`, hex).
public enum FileExt {
    public static let MTIME: UInt32 = 0x0000_0014
    public static let ATIME: UInt32 = 0x0000_0015
    public static let CREATETIME: UInt32 = 0x0000_0016
}

/// Separator between file records inside an attach list (FILELIST_SEPARATOR).
public let FILELIST_SEPARATOR: Character = "\u{07}"  // '\a'

/// Client-type marker reported in the version (VS:) string for diagnostics.
public let IPMSG_VER_MAC_TYPE: UInt32 = 0x0002_0000
