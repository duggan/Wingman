import Foundation

/// Minimal UDF reader: locates `sources/install.wim` inside a Windows ISO and
/// returns its data extents, so we can read just the WIM header + blob table
/// (≈5 MB) via ranged reads instead of downloading the whole ~6 GB image.
///
/// Only what's needed to find one file is implemented: anchor → volume
/// descriptor sequence (partition + logical volume) → file set → root directory
/// → `sources` → `install.wim` → its allocation descriptors. Layouts per
/// ECMA-167 / UDF. Field offsets verified against real Windows 11 media.
public enum UDFReader {
    static let sectorSize: UInt64 = 2048

    public enum Error: Swift.Error, CustomStringConvertible {
        case notUDF
        case notFound(String)
        case unsupported(String)
        public var description: String {
            switch self {
            case .notUDF: return "not a UDF volume (no anchor at sector 256)"
            case .notFound(let n): return "\(n) not found in the ISO"
            case .unsupported(let m): return "unsupported UDF layout: \(m)"
            }
        }
    }

    /// The ISO-byte extents of `sources/install.wim` (back-compat convenience).
    public static func installWimExtents(in src: ByteSource) throws -> [MappedByteSource.Extent] {
        try installImageExtents(in: src).extents
    }

    /// Locate the install image inside a Windows ISO, trying `install.wim` then
    /// `install.esd`, and return its name plus ISO-byte extents. (An ESD can't be
    /// split, but callers can still read its XML to describe it.)
    public static func installImageExtents(in src: ByteSource) throws -> (name: String, extents: [MappedByteSource.Extent]) {
        let (sourcesLBN, byteOffset) = try locateSources(in: src)
        for name in ["install.wim", "install.esd"] {
            do {
                let lbn = try entry(named: name, inDir: sourcesLBN, src: src, byteOffset: byteOffset, mustBeDir: false)
                let extents = try fileExtents(feLBN: lbn, src: src, byteOffset: byteOffset)
                guard !extents.isEmpty else { throw Error.notFound("\(name) data") }
                return (name, extents)
            } catch Error.notFound { continue }   // try the next candidate; other errors propagate
        }
        throw Error.notFound("sources/install.wim or sources/install.esd")
    }

    /// Anchor → volume descriptor sequence → file set → root → `sources`,
    /// returning the `sources` directory's ICB and the LBN→byte mapper.
    private static func locateSources(in src: ByteSource) throws -> (sourcesLBN: UInt64, byteOffset: (UInt64) -> UInt64) {
        // Anchor Volume Descriptor Pointer at sector 256.
        let avdp = try src.read(at: 256 * sectorSize, count: 512)
        guard u16(avdp, 0) == 2 else { throw Error.notUDF }
        let vdsLoc = u32(avdp, 20), vdsLen = u32(avdp, 16)

        // Walk the main Volume Descriptor Sequence for the partition start and
        // the File Set Descriptor location.
        var partStart: UInt64?, fsdLBN: UInt64?
        var s: UInt64 = 0
        let maxSectors = vdsLen / sectorSize + 2
        while s < maxSectors {
            let d = try src.read(at: (vdsLoc + s) * sectorSize, count: 600)
            switch u16(d, 0) {
            case 5:                                   // Partition Descriptor
                if partStart != nil { throw Error.unsupported("multiple partitions") }
                partStart = u32(d, 188)
            case 6: fsdLBN = u32(d, 248 + 4)         // Logical Volume Descriptor → FSD long_ad
            case 8: s = maxSectors                   // Terminating Descriptor
            default: break
            }
            s += 1
        }
        guard let partStart, let fsdLBN else { throw Error.notUDF }
        func byteOffset(_ lbn: UInt64) -> UInt64 { (partStart + lbn) * sectorSize }

        // File Set Descriptor → root directory ICB.
        let fsd = try src.read(at: byteOffset(fsdLBN), count: 600)
        guard u16(fsd, 0) == 256 else { throw Error.notUDF }
        let rootLBN = u32(fsd, 400 + 4)

        let sourcesLBN = try entry(named: "sources", inDir: rootLBN, src: src, byteOffset: byteOffset, mustBeDir: true)
        return (sourcesLBN, byteOffset)
    }

    // MARK: - File entries

    /// Parse a File Entry (261) / Extended File Entry (266): returns its
    /// allocation-descriptor area and type.
    private static func fileEntry(_ lbn: UInt64, src: ByteSource, byteOffset: (UInt64) -> UInt64) throws
        -> (fe: [UInt8], adType: Int, adStart: Int, adLen: Int) {
        let fe = try src.read(at: byteOffset(lbn), count: Int(sectorSize))
        let tag = u16(fe, 0)
        guard tag == 261 || tag == 266 else { throw Error.unsupported("file entry tag \(tag)") }
        let adType = u16(fe, 16 + 18) & 0x7          // ICBTag.Flags & 7: 0=short_ad, 1=long_ad
        let lenFieldOff = (tag == 266) ? 208 : 168   // L_EA, then L_AD
        let lEA = Int(u32(fe, lenFieldOff))
        let adLen = Int(u32(fe, lenFieldOff + 4))
        return (fe, adType, lenFieldOff + 8 + lEA, adLen)
    }

    /// All data extents described by a File Entry's allocation descriptors.
    private static func fileExtents(feLBN: UInt64, src: ByteSource, byteOffset: (UInt64) -> UInt64) throws
        -> [MappedByteSource.Extent] {
        let f = try fileEntry(feLBN, src: src, byteOffset: byteOffset)
        guard f.adType == 0 || f.adType == 1 else { throw Error.unsupported("AD type \(f.adType)") }
        let adSize = (f.adType == 1) ? 16 : 8        // long_ad is 16 bytes, short_ad 8
        // ADs are read inline from the File Entry. If L_AD overflows the FE block,
        // the file uses an allocation-extent continuation we don't follow — fail
        // clearly rather than return a truncated extent list.
        guard f.adStart + f.adLen <= f.fe.count else {
            throw Error.unsupported("allocation descriptors span a continuation extent (file too fragmented)")
        }
        var extents: [MappedByteSource.Extent] = []
        var p = f.adStart
        let end = f.adStart + f.adLen
        while p + adSize <= end {
            let raw = u32(f.fe, p)
            let len = raw & 0x3FFF_FFFF             // low 30 bits; top 2 bits are the extent type
            if len == 0 { break }
            switch Int(raw >> 30) {
            case 0: extents.append(.init(offset: byteOffset(u32(f.fe, p + 4)), length: len))   // recorded + allocated
            case 3: throw Error.unsupported("allocation-extent continuation descriptor")
            default: throw Error.unsupported("sparse/unallocated extent")
            }
            p += adSize
        }
        return extents
    }

    /// The first data extent of a (small, single-extent) directory.
    private static func dirExtent(_ lbn: UInt64, src: ByteSource, byteOffset: (UInt64) -> UInt64) throws
        -> (off: UInt64, len: UInt64) {
        let extents = try fileExtents(feLBN: lbn, src: src, byteOffset: byteOffset)
        guard extents.count == 1, let e = extents.first else {
            throw Error.unsupported("directory spans \(extents.count) extents (expected 1)")
        }
        return (e.offset, e.length)
    }

    /// Find a named entry in a directory; returns its File Entry LBN.
    private static func entry(named name: String, inDir dirLBN: UInt64, src: ByteSource,
                              byteOffset: (UInt64) -> UInt64, mustBeDir: Bool) throws -> UInt64 {
        let (off, len) = try dirExtent(dirLBN, src: src, byteOffset: byteOffset)
        guard len <= 16 * 1024 * 1024 else { throw Error.unsupported("directory implausibly large (\(len) bytes)") }
        let data = try src.read(at: off, count: Int(len))
        var i = 0
        while i + 38 <= data.count {
            guard u16(data, i) == 257 else { break }   // File Identifier Descriptor
            let chars = data[i + 18]
            let lFI = Int(data[i + 19])
            let icbLBN = u32(data, i + 20 + 4)
            let lIU = u16(data, i + 36)
            let nameStart = i + 38 + lIU
            let isParent = (chars & 0x08) != 0
            if !isParent, lFI > 0, nameStart + lFI <= data.count {
                let decoded = decodeDString(Array(data[nameStart ..< (nameStart + lFI)]))
                if decoded.caseInsensitiveCompare(name) == .orderedSame {
                    if mustBeDir && (chars & 0x02) == 0 { break }
                    return icbLBN
                }
            }
            var fidLen = 38 + lIU + lFI
            fidLen = (fidLen + 3) & ~3                  // 4-byte aligned
            i += fidLen
        }
        throw Error.notFound(name)
    }

    /// Decode a UDF dstring file identifier (compression id 8 = Latin-1, 16 = UTF-16BE).
    private static func decodeDString(_ raw: [UInt8]) -> String {
        guard let cid = raw.first else { return "" }
        let body = Array(raw.dropFirst())
        if cid == 16 {
            var u = [UInt16](); var j = 0
            while j + 1 < body.count { u.append(UInt16(body[j]) << 8 | UInt16(body[j + 1])); j += 2 }
            return String(decoding: u, as: UTF16.self)
        }
        return String(bytes: body, encoding: .isoLatin1) ?? ""
    }

    // MARK: - LE readers
    private static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0; for i in 0..<4 { v |= UInt64(b[o + i]) << (8 * i) }; return v
    }
}
