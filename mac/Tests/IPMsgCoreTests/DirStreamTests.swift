import XCTest
@testable import IPMsgCore

final class DirStreamTests: XCTestCase {

    func testHeaderLengthPrefixIsSelfDescribing() {
        let data = DirStream.encodeHeader(
            DirEntry(name: "photo.jpg", size: 0x4d2, attr: FileType.REGULAR,
                     mtime: 0x600d, ctime: 0x600e))
        // First 4 hex chars must equal the total byte length of the header.
        XCTAssertEqual(DirStream.headerLength(prefix: data), data.count)
        // The 5th byte is the ':' separator.
        XCTAssertEqual(data[data.index(data.startIndex, offsetBy: 4)], UInt8(ascii: ":"))
    }

    func testRoundTripRegularFile() {
        let e = DirEntry(name: "report.txt", size: 123456, attr: FileType.REGULAR,
                         mtime: 0x6500_0000, ctime: 0x6400_0000)
        let data = DirStream.encodeHeader(e)
        let back = DirStream.decodeHeader(data)
        XCTAssertEqual(back?.name, "report.txt")
        XCTAssertEqual(back?.size, 123456)
        XCTAssertTrue(back?.isRegular == true)
        XCTAssertEqual(back?.mtime, 0x6500_0000)
        XCTAssertEqual(back?.ctime, 0x6400_0000)
    }

    func testRoundTripDirAndRetParent() {
        let dir = DirStream.decodeHeader(DirStream.encodeHeader(
            DirEntry(name: "src", size: 0, attr: FileType.DIR, mtime: 1)))
        XCTAssertTrue(dir?.isDir == true)
        XCTAssertEqual(dir?.size, 0)

        let ret = DirStream.decodeHeader(DirStream.encodeHeader(
            DirEntry(name: ".", size: 0, attr: FileType.RETPARENT, mtime: 1)))
        XCTAssertTrue(ret?.isRetParent == true)
        XCTAssertEqual(ret?.name, ".")
    }

    func testMatchesWinFormatShape() {
        // The Win32 sender writes "HHHH:name:size:attr:14=mt:16=ct:".
        let data = DirStream.encodeHeader(
            DirEntry(name: "a", size: 0x10, attr: FileType.REGULAR, mtime: 0x20, ctime: 0x30))
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.hasSuffix(":a:10:1:14=20:16=30:"))
    }

    func testParsesPartialHeaderGuard() {
        // Fewer than 4 bytes -> length unknown.
        XCTAssertNil(DirStream.headerLength(prefix: Data([UInt8(ascii: "0"), UInt8(ascii: "0")])))
    }
}
