import Foundation

/// A random-access source of bytes — a local file, or (in WimTool) HTTP range
/// requests. Lets WimReader parse a WIM without caring whether the bytes come
/// from disk or the network.
public protocol ByteSource {
    /// Total addressable length, in bytes.
    var size: UInt64 { get }
    /// Read exactly `count` bytes at `offset`, or throw.
    func read(at offset: UInt64, count: Int) throws -> [UInt8]
}

public enum ByteSourceError: Error, CustomStringConvertible {
    case openFailed(String)
    case shortRead(UInt64, Int)
    public var description: String {
        switch self {
        case .openFailed(let p): return "could not open \(p)"
        case .shortRead(let o, let n): return "short read of \(n) bytes at offset \(o)"
        }
    }
}

/// A ByteSource backed by a local file.
public final class FileByteSource: ByteSource {
    private let handle: FileHandle
    public let size: UInt64

    public init(path: String) throws {
        guard let h = FileHandle(forReadingAtPath: path) else { throw ByteSourceError.openFailed(path) }
        handle = h
        size = (try? h.seekToEnd()) ?? 0
    }
    deinit { try? handle.close() }

    public func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        if count == 0 { return [] }
        guard count > 0, offset <= size, UInt64(count) <= size - offset else {
            throw ByteSourceError.shortRead(offset, count)
        }
        try handle.seek(toOffset: offset)
        guard let d = try handle.read(upToCount: count), d.count == count else {
            throw ByteSourceError.shortRead(offset, count)
        }
        return [UInt8](d)
    }
}

/// Presents a list of `(base offset, length)` extents over an underlying source
/// as a single contiguous logical space — e.g. `install.wim`, which the ISO
/// stores as several extents (no single extent may exceed ~1 GiB), viewed as one
/// continuous WIM. Reads that span extents are stitched together.
public final class MappedByteSource: ByteSource {
    public struct Extent { public let offset: UInt64; public let length: UInt64
        public init(offset: UInt64, length: UInt64) { self.offset = offset; self.length = length } }

    private let base: ByteSource
    private let extents: [Extent]
    public let size: UInt64

    public init(base: ByteSource, extents: [Extent]) {
        self.base = base
        self.extents = extents
        self.size = extents.reduce(0) { $0 + $1.length }
    }

    public func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        // Bounds BEFORE allocating: reserveCapacity on an unchecked count aborts
        // the process. After these guards, count ≤ stitched size.
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
            throw ByteSourceError.shortRead(offset, count)
        }
        var out = [UInt8]()
        out.reserveCapacity(count)
        var logical = offset
        var remaining = count
        var extentStart: UInt64 = 0
        for e in extents {
            let extentEnd = extentStart + e.length
            if remaining > 0, logical >= extentStart, logical < extentEnd {
                let within = logical - extentStart
                let avail = Int(min(UInt64(remaining), e.length - within))
                let (phys, overflow) = e.offset.addingReportingOverflow(within)
                guard !overflow else { throw ByteSourceError.shortRead(offset, count) }
                out.append(contentsOf: try base.read(at: phys, count: avail))
                logical += UInt64(avail)
                remaining -= avail
            }
            extentStart = extentEnd
            if remaining == 0 { break }
        }
        guard remaining == 0 else { throw ByteSourceError.shortRead(offset, count) }
        return out
    }
}
