import Foundation

// Pure-Swift reader for the WIM (Windows Imaging) on-disk format — enough to
// split a WIM without any compression codec. Field layouts are per wimlib
// 1.14.5 (include/wimlib/header.h, resource.h, src/blob_table.c). The split
// path never decompresses file data: blobs are copied verbatim and the blob
// table is (in retail Windows media) stored uncompressed.

public struct WimResourceHeader: Equatable {
    public let sizeInWim: UInt64        // bytes on disk (compressed size); 56-bit field
    public let flags: UInt8
    public let offsetInWim: UInt64
    public let uncompressedSize: UInt64

    public var isFree: Bool       { flags & 0x01 != 0 }
    public var isMetadata: Bool   { flags & 0x02 != 0 }
    public var isCompressed: Bool { flags & 0x04 != 0 }
    public var isSpanned: Bool    { flags & 0x08 != 0 }
    public var isSolid: Bool      { flags & 0x10 != 0 }
}

public struct WimBlob {
    public let reshdr: WimResourceHeader
    public let partNumber: UInt16
    public let refcnt: UInt32
    public let hash: [UInt8]            // SHA-1 of uncompressed data; all-zero if empty
    public var isMetadata: Bool { reshdr.isMetadata }
}

public struct WimHeader {
    public let version: UInt32
    public let flags: UInt32
    public let chunkSize: UInt32
    public let guid: [UInt8]            // 16 bytes
    public let partNumber: UInt16
    public let totalParts: UInt16
    public let imageCount: UInt32
    public let blobTable: WimResourceHeader
    public let xmlData: WimResourceHeader
    public let bootMetadata: WimResourceHeader
    public let bootIndex: UInt32
    public let integrityTable: WimResourceHeader

    public enum Compression: String { case none = "none", xpress = "XPRESS", lzx = "LZX", lzms = "LZMS", xpress2 = "XPRESS2" }
    public var compression: Compression {
        if flags & 0x00040000 != 0 { return .lzx }
        if flags & 0x00080000 != 0 { return .lzms }
        if flags & 0x00200000 != 0 { return .xpress2 }
        if flags & 0x00020000 != 0 { return .xpress }
        return .none
    }
}

public struct WimFile {
    public let header: WimHeader
    public let blobs: [WimBlob]
}

public enum WimError: Error, CustomStringConvertible {
    case shortRead(String)
    case badMagic
    case unsupportedVersion(UInt32)
    case compressedBlobTable
    case blobTableNotMultipleOf50(UInt64)

    public var description: String {
        switch self {
        case .shortRead(let what): return "short read of \(what)"
        case .badMagic: return "not a WIM file (bad magic)"
        case .unsupportedVersion(let v): return String(format: "unsupported WIM version 0x%X", v)
        case .compressedBlobTable: return "blob table is compressed (would need an LZX/XPRESS decoder; not present in retail Windows media)"
        case .blobTableNotMultipleOf50(let s): return "blob table size \(s) is not a multiple of 50 bytes"
        }
    }
}

public enum WimReader {
    public static let headerSize = 208
    public static let blobEntrySize = 50
    static let magic: [UInt8] = [0x4D, 0x53, 0x57, 0x49, 0x4D, 0x00, 0x00, 0x00]   // "MSWIM\0\0\0"

    /// Convenience: read a WIM from a local file path.
    public static func read(path: String) throws -> WimFile {
        try read(source: try FileByteSource(path: path))
    }

    /// Parse a WIM's header + blob table from any ByteSource (file or ranged).
    /// Touches only the header (208 B) + blob table (~5 MB) — never the payload.
    public static func read(source: ByteSource) throws -> WimFile {
        let b = try source.read(at: 0, count: headerSize)
        guard b.count == headerSize else { throw WimError.shortRead("header") }
        guard Array(b[0..<8]) == magic else { throw WimError.badMagic }
        // Only the modern, non-solid WIM version (0x10D00) has the field layout
        // we parse; refuse anything else rather than mis-parse foreign offsets.
        let version = u32(b, 12)
        guard version == 0x0001_0D00 else { throw WimError.unsupportedVersion(version) }

        let header = WimHeader(
            version: u32(b, 12),
            flags: u32(b, 16),
            chunkSize: u32(b, 20),
            guid: Array(b[24..<40]),
            partNumber: u16(b, 40),
            totalParts: u16(b, 42),
            imageCount: u32(b, 44),
            blobTable: reshdr(b, 48),
            xmlData: reshdr(b, 72),
            bootMetadata: reshdr(b, 96),
            bootIndex: u32(b, 120),
            integrityTable: reshdr(b, 124)
        )

        let bt = header.blobTable
        if bt.isCompressed { throw WimError.compressedBlobTable }
        guard bt.sizeInWim % UInt64(blobEntrySize) == 0 else {
            throw WimError.blobTableNotMultipleOf50(bt.sizeInWim)
        }
        // Bound the read against the source size + a sane cap before allocating,
        // so a crafted size field can't drive a huge read/allocation.
        let fileSize = source.size
        guard bt.offsetInWim <= fileSize, bt.sizeInWim <= fileSize - bt.offsetInWim else {
            throw WimError.shortRead("blob table extends past end of file")
        }
        guard bt.sizeInWim <= 512 * 1024 * 1024 else {
            throw WimError.shortRead("blob table implausibly large (\(bt.sizeInWim) bytes)")
        }

        let want = Int(bt.sizeInWim)
        let t = want == 0 ? [UInt8]() : try source.read(at: bt.offsetInWim, count: want)
        let count = want / blobEntrySize
        var blobs: [WimBlob] = []
        blobs.reserveCapacity(count)
        for i in 0..<count {
            let o = i * blobEntrySize
            blobs.append(WimBlob(
                reshdr: reshdr(t, o),
                partNumber: u16(t, o + 24),
                refcnt: u32(t, o + 26),
                hash: Array(t[(o + 30)..<(o + 50)])
            ))
        }
        return WimFile(header: header, blobs: blobs)
    }

    // MARK: - Little-endian readers

    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | (UInt16(b[o + 1]) << 8) }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        var v: UInt32 = 0; for i in 0..<4 { v |= UInt32(b[o + i]) << (8 * i) }; return v
    }
    static func uLE(_ b: [UInt8], _ o: Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0; for i in 0..<n { v |= UInt64(b[o + i]) << (8 * i) }; return v
    }
    static func reshdr(_ b: [UInt8], _ o: Int) -> WimResourceHeader {
        WimResourceHeader(sizeInWim: uLE(b, o, 7), flags: b[o + 7],
                          offsetInWim: uLE(b, o + 8, 8), uncompressedSize: uLE(b, o + 16, 8))
    }
}
