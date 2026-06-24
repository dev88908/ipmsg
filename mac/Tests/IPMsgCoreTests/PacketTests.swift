import XCTest
@testable import IPMsgCore

final class PacketTests: XCTestCase {

    func testEncodeHeaderFormat() {
        let data = PacketCodec.encode(
            packetNo: 100, userName: "shirouzu", hostName: "jupiter",
            command: Command.SENDMSG, body: "Hello")
        let s = String(decoding: data, as: UTF8.self)
        // ver:pkt:user:host:cmd:body  (NUL trails the body)
        XCTAssertTrue(s.hasPrefix("1:100:shirouzu:jupiter:32:Hello"))
        XCTAssertTrue([UInt8](data).contains(0))
    }

    func testRoundTripMessage() {
        let data = PacketCodec.encode(
            packetNo: 42, userName: "alice", hostName: "macbook",
            command: Command.SENDMSG | Opt.UTF8 | Opt.SENDCHECK, body: "こんにちは")
        let pkt = PacketCodec.decode(data)
        XCTAssertNotNil(pkt)
        XCTAssertEqual(pkt?.packetNo, 42)
        XCTAssertEqual(pkt?.userName, "alice")
        XCTAssertEqual(pkt?.hostName, "macbook")
        XCTAssertEqual(pkt?.commandMode, Command.SENDMSG)
        XCTAssertTrue(pkt!.hasOpt(Opt.SENDCHECK))
        XCTAssertEqual(pkt?.body, "こんにちは")
    }

    func testBodyWithColonsPreserved() {
        // A message body may contain ':' — only the first 5 colons are header.
        let data = PacketCodec.encode(
            packetNo: 7, userName: "u", hostName: "h",
            command: Command.SENDMSG | Opt.UTF8, body: "ratio 16:9 at 10:30")
        let pkt = PacketCodec.decode(data)
        XCTAssertEqual(pkt?.body, "ratio 16:9 at 10:30")
    }

    func testEntryExtBlock() {
        let block = "\nUN:alice\nHN:macbook\nNN:Alice\nGN:Dev\nVS:00020000:macOS"
        let data = PacketCodec.encode(
            packetNo: 1, userName: "alice", hostName: "macbook",
            command: Command.BR_ENTRY | Opt.CAPUTF8,
            body: "Alice", extra: "Dev", extBlock: block)
        let pkt = PacketCodec.decode(data)
        XCTAssertEqual(pkt?.extBlock["NN"], "Alice")
        XCTAssertEqual(pkt?.extBlock["GN"], "Dev")
        XCTAssertEqual(pkt?.extBlock["UN"], "alice")
    }

    func testFileListRoundTrip() {
        // Build a list the way the engine does, then parse it back.
        let size: UInt64 = 0x1234
        let mtime: UInt32 = 0x600d
        let attr = FileType.REGULAR
        var list = "5:report.pdf:\(String(size, radix: 16)):\(String(mtime, radix: 16)):\(String(attr, radix: 16)):"
        list.append(FILELIST_SEPARATOR)

        let data = PacketCodec.encode(
            packetNo: 9, userName: "u", hostName: "h",
            command: Command.SENDMSG | Opt.UTF8 | Opt.FILEATTACH,
            body: "see attached", extra: list)
        let pkt = PacketCodec.decode(data)!
        XCTAssertEqual(pkt.body, "see attached")
        XCTAssertTrue(pkt.hasOpt(Opt.FILEATTACH))
        XCTAssertEqual(pkt.segments.count, 2)

        let files = pkt.segments[1].split(separator: FILELIST_SEPARATOR).first!
        let f = files.split(separator: ":").map(String.init)
        XCTAssertEqual(f[0], "5")
        XCTAssertEqual(f[1], "report.pdf")
        XCTAssertEqual(UInt64(f[2], radix: 16), size)
    }

    func testRejectsMalformed() {
        XCTAssertNil(PacketCodec.decode(Data("not a packet".utf8)))
        XCTAssertNil(PacketCodec.decode(Data("1:2:3:4".utf8)))  // only 3 colons
    }
}
