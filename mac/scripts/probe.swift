// Runtime interop probe: pretend to be a Windows peer doing BR_ENTRY and
// verify the running macOS app answers with ANSENTRY (command mode 3).
//   usage: swift scripts/probe.swift
import Darwin
import Foundation

let BR_ENTRY: UInt32 = 0x0000_0001
let CAPUTF8:  UInt32 = 0x0100_0000
let ANSENTRY: UInt32 = 0x0000_0003

let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
var tv = timeval(tv_sec: 4, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

var dst = sockaddr_in()
dst.sin_family = sa_family_t(AF_INET)
dst.sin_port = UInt16(2425).bigEndian
dst.sin_addr.s_addr = inet_addr("127.0.0.1")

let cmd = BR_ENTRY | CAPUTF8
let body = "1:777:tester:probehost:\(cmd):Probe\u{0}Dev\u{0}\nUN:tester\nHN:probehost\nNN:Probe\nGN:Dev\nVS:00020000:probe"
let payload = Array(body.utf8)

_ = payload.withUnsafeBytes { raw in
    withUnsafePointer(to: &dst) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}
print("sent BR_ENTRY to 127.0.0.1:2425")

var buf = [UInt8](repeating: 0, count: 65536)
let n = recv(fd, &buf, buf.count, 0)
if n <= 0 { print("FAIL: no reply (timeout)"); exit(1) }

let reply = String(decoding: buf[0..<n], as: UTF8.self)
let header = reply.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
print("got \(n) bytes: \(reply.replacingOccurrences(of: "\u{0}", with: "<NUL>").replacingOccurrences(of: "\n", with: "<LF>"))")

if header.count >= 5, let c = UInt32(header[4]) {
    let mode = c & 0xff
    if mode == ANSENTRY {
        print("PASS: app answered ANSENTRY  user=\(header[2]) host=\(header[3])")
        exit(0)
    }
    print("FAIL: unexpected command mode \(mode)")
}
exit(1)
