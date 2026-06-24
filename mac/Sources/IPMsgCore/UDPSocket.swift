//  UDPSocket.swift
//  Minimal IPv4 UDP socket with broadcast support, used for the message channel.
//  Network.framework's NWConnection does not cleanly support classic subnet
//  broadcast, so we use BSD sockets directly.

import Foundation
import Darwin

public final class UDPSocket: @unchecked Sendable {
    private var fd: Int32 = -1
    private let port: UInt16
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "ipmsg.udp.rx")

    /// Called for every datagram: (payload, senderIPv4, senderPort).
    public var onReceive: ((Data, String, UInt16) -> Void)?

    public init(port: UInt16) {
        self.port = port
    }

    deinit { close() }

    /// Bind the socket and start receiving. Throws on bind failure.
    public func start() throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw err("socket") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else { let e = err("bind"); Darwin.close(fd); fd = -1; throw e }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        source = src
        src.resume()
    }

    public func close() {
        source?.cancel()
        source = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(fd, &buf, buf.count, 0, sa, &fromLen)
            }
        }
        guard n > 0 else { return }
        let data = Data(buf[0..<n])
        let ip = ipString(from.sin_addr)
        let p = UInt16(bigEndian: from.sin_port)
        onReceive?(data, ip, p)
    }

    /// Send to a specific host:port.
    public func send(_ data: Data, to host: String, port: UInt16) {
        guard fd >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        if addr.sin_addr.s_addr == INADDR_NONE { return }
        _ = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Broadcast to 255.255.255.255 and to every interface's directed broadcast.
    public func broadcast(_ data: Data, port: UInt16) {
        send(data, to: "255.255.255.255", port: port)
        for addr in NetInterfaces.directedBroadcasts() {
            send(data, to: addr, port: port)
        }
    }

    private func ipString(_ a: in_addr) -> String {
        var addr = a
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    private func err(_ what: String) -> NSError {
        NSError(domain: "UDPSocket", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
    }
}

/// Helpers to enumerate local IPv4 interfaces and their broadcast addresses.
public enum NetInterfaces {

    /// Directed broadcast address for each non-loopback IPv4 interface.
    public static func directedBroadcasts() -> [String] {
        var result: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return result }
        defer { freeifaddrs(ifap) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_BROADCAST) != 0,
                  let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = p.pointee.ifa_netmask
            else { continue }

            let ip = sockaddrV4(sa)
            let nm = sockaddrV4(mask)
            let bcast = (ip & nm) | ~nm
            result.append(ipv4String(bcast))
        }
        return result
    }

    /// Best-guess primary local IPv4 address (for display / file-server host).
    public static func primaryIPv4() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }

        var fallback: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let ip = ipv4String(sockaddrV4(sa))
            let name = String(cString: p.pointee.ifa_name)
            if name.hasPrefix("en") { return ip }   // prefer Ethernet/Wi-Fi
            fallback = fallback ?? ip
        }
        return fallback
    }

    private static func sockaddrV4(_ sa: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
    }

    private static func ipv4String(_ v: UInt32) -> String {
        "\((v >> 24) & 0xff).\((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
    }
}
