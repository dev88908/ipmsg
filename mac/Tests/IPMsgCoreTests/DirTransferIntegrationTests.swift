import XCTest
@testable import IPMsgCore

/// End-to-end: FileServer streams a real directory tree over loopback TCP and
/// DirectoryReceiver reconstructs it on disk. Exercises the GETDIRFILES path
/// exactly as it runs against a Windows peer.
final class DirTransferIntegrationTests: XCTestCase {

    func testDirectoryTreeRoundTripOverTCP() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ipmsg-itest-\(UUID().uuidString)")
        let src = tmp.appendingPathComponent("payload")
        let dst = tmp.appendingPathComponent("dest")
        try fm.createDirectory(at: src.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Source tree: top file, nested file, and a binary blob a couple chunks long.
        let blob = Data((0..<(150 * 1024)).map { UInt8($0 & 0xff) })
        try Data("hello".utf8).write(to: src.appendingPathComponent("a.txt"))
        try Data("nested".utf8).write(to: src.appendingPathComponent("sub/b.txt"))
        try blob.write(to: src.appendingPathComponent("sub/deep/c.bin"))
        try Data().write(to: src.appendingPathComponent("sub/empty.dat"))   // 0-byte file

        let port: UInt16 = 24250
        let server = FileServer(port: port)
        server.register(packetNo: 0xABCD, files: [7: src])
        try server.start()
        defer { server.stop() }

        let exp = expectation(description: "download")
        var received: URL?
        var failure: Error?

        let req = DirectoryReceiver.Request(
            host: "127.0.0.1", port: port, packetNo: 0xABCD, fileID: 7,
            totalSize: 0, rootName: "payload",
            localUser: "tester", localHost: "host", requestPacketNo: 1)

        DirectoryReceiver.download(req, to: dst, progress: { _, _ in }) { result in
            switch result {
            case .success(let url): received = url
            case .failure(let e): failure = e
            }
            exp.fulfill()
        }

        wait(for: [exp], timeout: 15)
        if let failure { XCTFail("download failed: \(failure)"); return }
        XCTAssertNotNil(received)

        let root = dst.appendingPathComponent("payload")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt")), "hello")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("sub/b.txt")), "nested")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("sub/deep/c.bin")), blob)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("sub/empty.dat").path))
    }

    func testRegularFileRoundTripOverTCP() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ipmsg-ftest-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let blob = Data((0..<(200 * 1024)).map { UInt8(($0 * 7) & 0xff) })
        let src = tmp.appendingPathComponent("movie.bin")
        try blob.write(to: src)
        let dst = tmp.appendingPathComponent("out.bin")

        let port: UInt16 = 24251
        let server = FileServer(port: port)
        server.register(packetNo: 0x1234, files: [3: src])
        try server.start()
        defer { server.stop() }

        let exp = expectation(description: "file download")
        var ok = false
        let req = FileDownloader.Request(
            host: "127.0.0.1", port: port, packetNo: 0x1234, fileID: 3,
            size: UInt64(blob.count), localUser: "t", localHost: "h", requestPacketNo: 1)
        FileDownloader.download(req, to: dst, progress: { _, _ in }) { result in
            if case .success = result { ok = true }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
        XCTAssertTrue(ok)
        XCTAssertEqual(try Data(contentsOf: dst), blob)
    }
}
