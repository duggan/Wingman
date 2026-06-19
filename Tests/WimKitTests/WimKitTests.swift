import XCTest
@testable import WimKit

final class WimKitTests: XCTestCase {

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: "sample", withExtension: "wim", subdirectory: "Fixtures"),
            "sample.wim fixture missing"
        )
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wimkit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func key(_ b: WimBlob) -> String {
        b.hash.map { String(format: "%02x", $0) }.joined() + ":\(b.reshdr.sizeInWim)"
    }

    // MARK: - Reader

    func testReadHeaderAndInventory() throws {
        let wim = try WimReader.read(path: fixtureURL().path)
        XCTAssertEqual(wim.header.version, 0x0001_0D00)
        XCTAssertEqual(wim.header.imageCount, 2)
        XCTAssertFalse(wim.header.blobTable.isCompressed, "retail-style blob table is uncompressed")
        let metadata = wim.blobs.filter { $0.isMetadata }
        XCTAssertEqual(UInt32(metadata.count), wim.header.imageCount, "one metadata resource per image")
        XCTAssertFalse(wim.blobs.contains { $0.reshdr.isSolid }, "fixture must be non-solid")
        XCTAssertGreaterThan(wim.blobs.count, metadata.count, "should have file blobs beyond metadata")
        XCTAssertTrue(wim.blobs.allSatisfy { $0.hash.count == 20 }, "SHA-1 hashes are 20 bytes")
    }

    func testBadMagicRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let junk = dir.appendingPathComponent("not.wim")
        try Data(repeating: 0x41, count: 1024).write(to: junk)
        XCTAssertThrowsError(try WimReader.read(path: junk.path)) { err in
            guard case WimError.badMagic = err else { return XCTFail("expected .badMagic, got \(err)") }
        }
    }

    // MARK: - Splitter

    func testSplitRoundTrip() throws {
        let src = try fixtureURL().path
        let original = try WimReader.read(path: src)
        let largest = original.blobs.map { $0.reshdr.sizeInWim }.max() ?? 0
        let maxPart = largest + 64 * 1024   // forces several parts, every blob still fits

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parts = try WimSplitter.split(
            wimPath: src,
            firstPartPath: dir.appendingPathComponent("out.swm").path,
            maxPartSize: maxPart
        )
        XCTAssertGreaterThanOrEqual(parts.count, 2, "expected a multi-part split")

        let partFiles = try parts.map { try WimReader.read(path: $0) }
        let SPANNED: UInt32 = 0x08
        for (i, p) in partFiles.enumerated() {
            XCTAssertNotEqual(p.header.flags & SPANNED, 0, "part \(i + 1) must carry the SPANNED flag")
            XCTAssertEqual(p.header.guid, original.header.guid, "every part shares the WIM GUID")
            XCTAssertEqual(Int(p.header.partNumber), i + 1)
            XCTAssertEqual(Int(p.header.totalParts), parts.count)
            XCTAssertEqual(p.header.imageCount, original.header.imageCount)
        }

        // Metadata resources live only in part 1.
        XCTAssertEqual(partFiles[0].blobs.filter { $0.isMetadata }.count,
                       original.blobs.filter { $0.isMetadata }.count)
        for p in partFiles.dropFirst() {
            XCTAssertTrue(p.blobs.allSatisfy { !$0.isMetadata }, "only part 1 carries metadata")
        }

        // Every original blob appears exactly once across the parts, hash + size intact.
        let union = partFiles.flatMap { $0.blobs }.map(key)
        XCTAssertEqual(Set(union), Set(original.blobs.map(key)), "split preserves exactly the same blobs")
        XCTAssertEqual(union.count, original.blobs.count, "no blob lost or duplicated")
    }

    func testPartTooLargeIsRejectedAndLeavesNothing() throws {
        let src = try fixtureURL().path
        let largest = try WimReader.read(path: src).blobs.map { $0.reshdr.sizeInWim }.max() ?? 0
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(
            try WimSplitter.split(
                wimPath: src,
                firstPartPath: dir.appendingPathComponent("x.swm").path,
                maxPartSize: largest / 2   // a single blob cannot fit
            )
        ) { err in
            guard case WimSplitError.partTooLarge = err else {
                return XCTFail("expected .partTooLarge, got \(err)")
            }
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "a refused split must not leave partial .swm files")
    }

    // MARK: - ByteSource (extent stitching used by the ISO probe)

    func testMappedByteSourceStitchesAcrossExtents() throws {
        let base = ArrayByteSource((0..<300).map { UInt8($0 % 256) })
        // Two non-contiguous extents → one logical space of 110 bytes.
        let mapped = MappedByteSource(base: base, extents: [
            .init(offset: 100, length: 50),   // logical 0..<50
            .init(offset: 200, length: 60),   // logical 50..<110
        ])
        XCTAssertEqual(mapped.size, 110)
        XCTAssertEqual(try mapped.read(at: 0, count: 5), (100..<105).map { UInt8($0) })
        // A read straddling the extent boundary must stitch base 148,149 + 200,201.
        XCTAssertEqual(try mapped.read(at: 48, count: 4), [148, 149, 200, 201])
        XCTAssertEqual(try mapped.read(at: 0, count: 110).count, 110)
        XCTAssertThrowsError(try mapped.read(at: 100, count: 20), "reads past the end must throw")
    }

    func testMappedByteSourceRejectsWildCountWithoutCrashing() {
        let mapped = MappedByteSource(base: ArrayByteSource([1, 2, 3, 4]), extents: [.init(offset: 0, length: 4)])
        // A wild count must throw — not abort the process via reserveCapacity.
        XCTAssertThrowsError(try mapped.read(at: 0, count: Int.max - 1))
        XCTAssertThrowsError(try mapped.read(at: 0, count: 100))
        XCTAssertThrowsError(try mapped.read(at: 4, count: 1))
    }

    // MARK: - WindowsImage (version/edition detection from the WIM XML resource)

    /// Build a minimal in-memory WIM: 208-byte header (magic + version + xmlData
    /// reshdr) followed by the UTF-16LE-with-BOM XML resource.
    private func makeWim(xml: String, version: UInt32 = WindowsImage.WIM_VERSION_DEFAULT) -> ArrayByteSource {
        var xmlBytes: [UInt8] = [0xFF, 0xFE]                       // UTF-16LE BOM
        for u in xml.utf16 { xmlBytes.append(UInt8(u & 0xff)); xmlBytes.append(UInt8(u >> 8)) }
        var h = [UInt8](repeating: 0, count: 208)
        for (i, b) in [0x4D, 0x53, 0x57, 0x49, 0x4D, 0, 0, 0].enumerated() { h[i] = UInt8(b) }
        func putLE(_ off: Int, _ v: UInt64, _ n: Int) { for i in 0..<n { h[off + i] = UInt8((v >> (8 * i)) & 0xff) } }
        putLE(12, UInt64(version), 4)
        let off = UInt64(208), size = UInt64(xmlBytes.count)
        putLE(72, size, 7); h[79] = 0; putLE(80, off, 8); putLE(88, size, 8)   // xmlData reshdr
        return ArrayByteSource(h + xmlBytes)
    }

    private func imageXML(_ items: [(idx: Int, name: String, edition: String, build: Int)]) -> String {
        let body = items.map {
            "<IMAGE INDEX=\"\($0.idx)\"><NAME>\($0.name)</NAME><DISPLAYNAME>\($0.name)</DISPLAYNAME>" +
            "<WINDOWS><EDITIONID>\($0.edition)</EDITIONID><VERSION><MAJOR>10</MAJOR><MINOR>0</MINOR>" +
            "<BUILD>\($0.build)</BUILD></VERSION></WINDOWS></IMAGE>"
        }.joined()
        return "<WIM>\(body)</WIM>"
    }

    func testDetectsWindows11ByBuild() throws {
        let src = makeWim(xml: imageXML([(1, "Windows 11 Pro", "Professional", 26200),
                                         (2, "Windows 11 Home", "Core", 26200)]))
        let info = try WindowsImage.read(source: src)
        XCTAssertEqual(info.product, .windows11)
        XCTAssertEqual(info.build, 26200)
        XCTAssertTrue(info.isSplittable)
        XCTAssertEqual(info.editions.count, 2)
        XCTAssertEqual(info.editions.first?.editionID, "Professional")
        XCTAssertEqual(info.editions.last?.index, 2)
    }

    func testDetectsWindows10ByBuild() throws {
        let src = makeWim(xml: imageXML([(1, "Windows 10 Home", "Core", 19041)]))
        let info = try WindowsImage.read(source: src)
        XCTAssertEqual(info.product, .windows10)   // build 19041 < 22000
        XCTAssertEqual(info.build, 19041)
        XCTAssertTrue(info.isSplittable)
    }

    func testEsdVersionIsNotSplittable() throws {
        // Same XML, but a solid ESD on-disk version (0xE00): describable, not splittable.
        let src = makeWim(xml: imageXML([(1, "Windows 10 Pro", "Professional", 19045)]),
                          version: WindowsImage.WIM_VERSION_SOLID)
        let info = try WindowsImage.read(source: src)
        XCTAssertEqual(info.product, .windows10)
        XCTAssertFalse(info.isSplittable, "an ESD (0xE00) must be flagged unsplittable")
    }

    func testFallsBackToNameWhenBuildMissing() throws {
        let src = makeWim(xml: "<WIM><IMAGE INDEX=\"1\"><NAME>Windows 11 Enterprise</NAME></IMAGE></WIM>")
        let info = try WindowsImage.read(source: src)
        XCTAssertEqual(info.product, .windows11)   // no <BUILD>; name decides
        XCTAssertEqual(info.build, 0)
    }

    func testBadMagicRejectedByWindowsImage() {
        let junk = ArrayByteSource([UInt8](repeating: 0x41, count: 256))
        XCTAssertThrowsError(try WindowsImage.read(source: junk)) { err in
            guard case WindowsImage.DetectError.badMagic = err else { return XCTFail("expected .badMagic, got \(err)") }
        }
    }
}

/// In-memory ByteSource for tests.
private struct ArrayByteSource: ByteSource {
    let bytes: [UInt8]
    init(_ b: [UInt8]) { bytes = b }
    var size: UInt64 { UInt64(bytes.count) }
    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        let start = Int(offset)
        guard start + count <= bytes.count else { throw ByteSourceError.shortRead(offset, count) }
        return Array(bytes[start ..< start + count])
    }
}
