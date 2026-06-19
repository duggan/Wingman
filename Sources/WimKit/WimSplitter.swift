import Foundation

public enum WimSplitError: Error, CustomStringConvertible {
    case solidUnsupported
    case partTooLarge(UInt64, UInt64)
    case cancelled
    case readFailed(String)
    case writeFailed(String)
    public var description: String {
        switch self {
        case .solidUnsupported: return "WIM contains solid resources; split unsupported (export non-solid first)"
        case .partTooLarge(let need, let max): return "a single resource needs \(need) bytes but the part limit is \(max) — raise the part size"
        case .cancelled: return "split cancelled"
        case .readFailed(let s): return "read failed: \(s)"
        case .writeFailed(let s): return "write failed: \(s)"
        }
    }
}

/// Splits an on-disk WIM into `.swm` parts by COPYING already-compressed blobs
/// verbatim — no compression codec involved. Output format mirrors wimlib's
/// split (verified empirically): one shared GUID, every part flagged SPANNED,
/// metadata resources in part 1, each part's (uncompressed) blob table listing
/// only the blobs it physically contains, and the XML copied into every part.
public enum WimSplitter {
    static let headerSize = 208
    static let entrySize = 50
    static let WIM_HDR_FLAG_SPANNED: UInt32 = 0x08
    static let WIM_RESHDR_FLAG_METADATA: UInt8 = 0x02
    static let magic: [UInt8] = [0x4D, 0x53, 0x57, 0x49, 0x4D, 0x00, 0x00, 0x00]

    public struct PartProgress {
        public let partNumber: Int
        public let totalParts: Int
        public let completedBytes: UInt64
        public let totalBytes: UInt64
    }

    /// Split `wimPath` into `firstPartPath` (+ numbered siblings) so each part's
    /// *on-disk* size (header + copied blobs + blob table + XML) stays within
    /// `maxPartSize`. Returns the written part paths. `isCancelled` is polled
    /// during copying; if it returns true the split aborts and removes any parts
    /// written so far.
    @discardableResult
    public static func split(wimPath: String,
                             firstPartPath: String,
                             maxPartSize: UInt64,
                             isCancelled: () -> Bool = { false },
                             progress: ((PartProgress) -> Void)? = nil) throws -> [String] {
        let wim = try WimReader.read(path: wimPath)
        if wim.blobs.contains(where: { $0.reshdr.isSolid }) { throw WimSplitError.solidUnsupported }

        let src = try FileHandle(forReadingFrom: URL(fileURLWithPath: wimPath))
        defer { try? src.close() }
        // XML is copied verbatim into every part, so it is part of each part's
        // fixed overhead (alongside the 208-byte header).
        let xml = try readRange(src, offset: wim.header.xmlData.offsetInWim, size: wim.header.xmlData.sizeInWim)
        let perPartOverhead = UInt64(headerSize) + UInt64(xml.count)
        let entry = UInt64(entrySize)

        let metadata = wim.blobs.filter { $0.isMetadata }
        let files = wim.blobs.filter { !$0.isMetadata }
            .sorted { $0.reshdr.offsetInWim < $1.reshdr.offsetInWim }

        // Pre-flight: a part costs the fixed overhead + (size + 50-byte entry) per
        // blob. If a single blob or the metadata set can't fit a part, fail cleanly
        // up front rather than emitting an oversized part that dies mid-write on FAT32.
        if let biggest = files.map({ $0.reshdr.sizeInWim }).max(), biggest + entry + perPartOverhead > maxPartSize {
            throw WimSplitError.partTooLarge(biggest + entry + perPartOverhead, maxPartSize)
        }
        let metaCost = metadata.reduce(perPartOverhead) { $0 + $1.reshdr.sizeInWim + entry }
        if metaCost > maxPartSize { throw WimSplitError.partTooLarge(metaCost, maxPartSize) }

        // Bin-pack with accurate on-disk accounting (metadata all in part 1). The
        // pre-flight guarantees any single blob fits a fresh part, so we can roll
        // to a new part whenever the projected size would exceed the limit.
        var parts: [[WimBlob]] = [metadata]
        var sizes: [UInt64] = [metaCost]
        for blob in files {
            var i = parts.count - 1
            if sizes[i] + blob.reshdr.sizeInWim + entry > maxPartSize {
                parts.append([]); sizes.append(perPartOverhead); i += 1
            }
            parts[i].append(blob)
            sizes[i] += blob.reshdr.sizeInWim + entry
        }

        let totalParts = parts.count
        let grandTotal = wim.blobs.reduce(UInt64(0)) { $0 + $1.reshdr.sizeInWim }
        var completed: UInt64 = 0

        var paths: [String] = []
        do {
            for (idx, partBlobs) in parts.enumerated() {
                let partNumber = idx + 1
                let path = partPath(firstPartPath, partNumber: partNumber)
                paths.append(path)
                try writePart(path: path, partBlobs: partBlobs, partNumber: partNumber, totalParts: totalParts,
                              header: wim.header, xml: xml, src: src, isCancelled: isCancelled) { n in
                    completed += n
                    progress?(PartProgress(partNumber: partNumber, totalParts: totalParts,
                                           completedBytes: completed, totalBytes: grandTotal))
                }
            }
        } catch {
            // Leave the destination clean: remove every part written so far.
            for p in paths { try? FileManager.default.removeItem(atPath: p) }
            throw error
        }
        return paths
    }

    // MARK: - Part writing

    private static func writePart(path: String, partBlobs: [WimBlob], partNumber: Int, totalParts: Int,
                                  header: WimHeader, xml: [UInt8], src: FileHandle,
                                  isCancelled: () -> Bool, onChunk: (UInt64) -> Void) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let out = FileHandle(forWritingAtPath: path) else { throw WimSplitError.writeFailed(path) }
        var ok = false
        defer {
            try? out.close()
            if !ok { try? FileManager.default.removeItem(atPath: path) }   // never leave a partial .swm
        }

        try out.write(contentsOf: Data(count: headerSize))   // placeholder; rewritten below

        var newOffsets: [UInt64] = []
        var pos = UInt64(headerSize)
        for blob in partBlobs {
            newOffsets.append(pos)
            try copyRange(from: src, offset: blob.reshdr.offsetInWim, size: blob.reshdr.sizeInWim, to: out, isCancelled: isCancelled, onChunk: onChunk)
            pos += blob.reshdr.sizeInWim
        }

        let tableOffset = pos
        var table: [UInt8] = []
        table.reserveCapacity(partBlobs.count * entrySize)
        for (i, blob) in partBlobs.enumerated() {
            table.append(contentsOf: entryBytes(blob: blob, newOffset: newOffsets[i], partNumber: partNumber))
        }
        try out.write(contentsOf: Data(table))
        pos += UInt64(table.count)

        let xmlOffset = pos
        try out.write(contentsOf: Data(xml))

        let hdr = headerBytes(header: header, partNumber: partNumber, totalParts: totalParts,
                              blobTableOffset: tableOffset, blobTableSize: UInt64(table.count),
                              xmlOffset: xmlOffset, xmlSize: UInt64(xml.count))
        try out.seek(toOffset: 0)
        try out.write(contentsOf: Data(hdr))
        try out.synchronize()   // flush this part to the USB before declaring it complete
        ok = true
    }

    // MARK: - Encoding

    static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * $0)) & 0xff) } }

    static func reshdrBytes(size: UInt64, flags: UInt8, offset: UInt64, usize: UInt64) -> [UInt8] {
        var b = le(size, 7); b.append(flags); b += le(offset, 8); b += le(usize, 8); return b   // 24
    }

    static func entryBytes(blob: WimBlob, newOffset: UInt64, partNumber: Int) -> [UInt8] {
        var b = reshdrBytes(size: blob.reshdr.sizeInWim, flags: blob.reshdr.flags,
                            offset: newOffset, usize: blob.reshdr.uncompressedSize)
        b += le(UInt64(partNumber), 2)
        b += le(UInt64(blob.refcnt), 4)
        b += blob.hash      // 20
        return b            // 50
    }

    static func headerBytes(header h: WimHeader, partNumber: Int, totalParts: Int,
                            blobTableOffset: UInt64, blobTableSize: UInt64,
                            xmlOffset: UInt64, xmlSize: UInt64) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: headerSize)
        func put(_ off: Int, _ bytes: [UInt8]) { for (i, x) in bytes.enumerated() { b[off + i] = x } }
        put(0, magic)
        put(8, le(UInt64(headerSize), 4))
        put(12, le(UInt64(h.version), 4))
        put(16, le(UInt64(h.flags | WIM_HDR_FLAG_SPANNED), 4))
        put(20, le(UInt64(h.chunkSize), 4))
        put(24, h.guid)                                   // shared across parts
        put(40, le(UInt64(partNumber), 2))
        put(42, le(UInt64(totalParts), 2))
        put(44, le(UInt64(h.imageCount), 4))
        put(48, reshdrBytes(size: blobTableSize, flags: WIM_RESHDR_FLAG_METADATA, offset: blobTableOffset, usize: blobTableSize))
        put(72, reshdrBytes(size: xmlSize, flags: WIM_RESHDR_FLAG_METADATA, offset: xmlOffset, usize: xmlSize))
        // boot_metadata reshdr (96) left zero (install.wim is not bootable)
        put(120, le(UInt64(h.bootIndex), 4))
        // integrity reshdr (124) left zero
        return b
    }

    // MARK: - Naming & I/O

    static func partPath(_ first: String, partNumber: Int) -> String {
        if partNumber == 1 { return first }
        let url = URL(fileURLWithPath: first)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().path
        return ext.isEmpty ? "\(base)\(partNumber)" : "\(base)\(partNumber).\(ext)"
    }

    static func readRange(_ fh: FileHandle, offset: UInt64, size: UInt64) throws -> [UInt8] {
        try fh.seek(toOffset: offset)
        guard let d = try fh.read(upToCount: Int(size)), d.count == Int(size) else {
            throw WimSplitError.readFailed("range @\(offset) len \(size)")
        }
        return [UInt8](d)
    }

    static func copyRange(from src: FileHandle, offset: UInt64, size: UInt64, to out: FileHandle, isCancelled: () -> Bool, onChunk: (UInt64) -> Void) throws {
        try src.seek(toOffset: offset)
        var remaining = size
        let chunk = 8 * 1024 * 1024
        while remaining > 0 {
            if isCancelled() { throw WimSplitError.cancelled }
            let n = Int(min(UInt64(chunk), remaining))
            guard let d = try src.read(upToCount: n), d.count == n else {
                throw WimSplitError.readFailed("blob @\(offset)")
            }
            try out.write(contentsOf: d)
            remaining -= UInt64(n)
            onChunk(UInt64(n))
        }
    }
}
