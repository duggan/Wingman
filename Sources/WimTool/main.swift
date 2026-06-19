import Foundation
import WimKit

// WimTool — inspect/split a Windows install.wim, or PROBE one in place (locating
// it inside an ISO via UDF and reading only the header + blob table, ~5 MB, over
// a local file or HTTP range requests).
//
//   WimTool <install.wim>                        # inspect + compatibility check
//   WimTool split <install.wim> <out.swm> <MiB>  # split into parts
//   WimTool probe <iso-path-or-url>              # locate install.wim in an ISO and check it (~5 MB read)

func human(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - HTTP range ByteSource (for `probe <url>`)

final class HTTPByteSource: ByteSource {
    let url: String
    let size: UInt64

    /// Run curl, capturing stdout + stderr; reads pipes before waiting (no deadlock).
    private static func curl(_ args: [String]) throws -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, out, String(data: err, encoding: .utf8) ?? "")
    }

    init(url: String) throws {
        self.url = url
        // Probe a 1-byte range; a compliant server replies 206 with
        // "Content-Range: bytes 0-0/TOTAL". Anything else = ranges unsupported.
        let r = try Self.curl(["-sS", "-r", "0-0", "-D", "-", "-o", "/dev/null", url])
        guard r.status == 0 else {
            throw ByteSourceError.openFailed("\(url): curl exited \(r.status): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        var total: UInt64?
        var partial = false
        for raw in (String(data: r.out, encoding: .utf8) ?? "").split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if line.hasPrefix("http/"), line.contains(" 206") { partial = true }
            if line.hasPrefix("content-range:"), let slash = line.lastIndex(of: "/") {
                let tail = line[line.index(after: slash)...].trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty, tail.allSatisfy(\.isNumber) { total = UInt64(tail) }
            }
        }
        guard partial, let total else {
            throw ByteSourceError.openFailed("\(url): server does not honor HTTP byte ranges (no 206 / Content-Range)")
        }
        self.size = total
    }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        if count == 0 { return [] }
        // --max-filesize caps the transfer: a Range-ignoring 200 (the whole ISO)
        // fails fast instead of streaming ~6 GB into memory.
        let r = try Self.curl(["-sS", "--fail", "--max-filesize", "\(count)",
                               "-r", "\(offset)-\(offset + UInt64(count) - 1)", url])
        guard r.status == 0 else {
            throw ByteSourceError.openFailed("\(url): curl exited \(r.status) for bytes \(offset)-\(offset + UInt64(count) - 1): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard r.out.count == count else { throw ByteSourceError.shortRead(offset, count) }
        return [UInt8](r.out)
    }
}

// MARK: - Windows edition reporting

func printWindows(_ info: WindowsImage) {
    print("Windows edition")
    print("  product   : \(info.product.rawValue)\(info.build > 0 ? "  (build \(info.build))" : "")")
    print("  editions  : \(info.editions.count)")
    for e in info.editions.prefix(20) {
        let id = e.editionID.isEmpty ? "" : "  [\(e.editionID)]"
        print("    \(e.index). \(e.displayName.isEmpty ? e.name : e.displayName)\(id)")
    }
    if info.editions.count > 20 { print("    … and \(info.editions.count - 20) more") }
    print("")
}

// MARK: - Inspect / compatibility gate

func inspect(_ wim: WimFile) -> Bool {
    let h = wim.header
    print("WIM header")
    print(String(format: "  version      : 0x%05X", h.version))
    print("  compression  : \(h.compression.rawValue)  (chunk \(h.chunkSize))")
    print("  part/total   : \(h.partNumber)/\(h.totalParts)")
    print("  image count  : \(h.imageCount)")
    print("  blob table   : offset=\(h.blobTable.offsetInWim) size=\(human(h.blobTable.sizeInWim)) \(h.blobTable.isCompressed ? "COMPRESSED" : "uncompressed")")
    print("")

    let blobs = wim.blobs
    let metadata = blobs.filter { $0.isMetadata }
    let solid = blobs.filter { $0.reshdr.isSolid }
    let largest = blobs.map { $0.reshdr.sizeInWim }.max() ?? 0
    let placed = blobs.filter { $0.reshdr.sizeInWim > 0 }.sorted { $0.reshdr.offsetInWim < $1.reshdr.offsetInWim }
    var overlaps = 0
    var prevEnd = UInt64(WimReader.headerSize)
    for blob in placed {
        if blob.reshdr.offsetInWim < prevEnd { overlaps += 1 }
        prevEnd = max(prevEnd, blob.reshdr.offsetInWim + blob.reshdr.sizeInWim)
    }

    print("Blob inventory")
    print("  blob entries        : \(blobs.count)")
    print("  metadata resources  : \(metadata.count)   (expect == image count \(h.imageCount))")
    print("  solid resources     : \(solid.count)   (expect 0 — else a codec is needed)")
    print("  largest blob (wim)  : \(human(largest))   (must be < 4 GiB to fit FAT32)")
    print("  overlapping extents : \(overlaps)")
    print("")

    var ok = true
    func check(_ label: String, _ cond: Bool) { print("  [\(cond ? "PASS" : "FAIL")] \(label)"); if !cond { ok = false } }
    print("Compatibility checks")
    check("blob table uncompressed (no codec needed)", !h.blobTable.isCompressed)
    check("metadata resources == image count", UInt32(metadata.count) == h.imageCount)
    check("no solid resources", solid.isEmpty)
    check("largest blob fits FAT32 (< 4 GiB)", largest < 4 * 1024 * 1024 * 1024)
    check("no overlapping resource extents", overlaps == 0)
    print("")
    print(ok ? "✅ Compatible — Wingman can build a bootable USB from this image."
             : "❌ Not compatible — this image uses a WIM layout Wingman can't split (see failures above).")
    return ok
}

// MARK: - Dispatch

let args = CommandLine.arguments
guard args.count >= 2 else {
    err("""
    usage:
      WimTool <install.wim>                        # inspect + compatibility check
      WimTool split <install.wim> <out.swm> <MiB>  # split into parts
      WimTool probe <iso-path-or-url>              # locate install.wim in an ISO and check it (~5 MB read)
    """)
    exit(2)
}

switch args[1] {
case "split":
    guard args.count >= 5, let mib = UInt64(args[4]) else {
        err("usage: WimTool split <install.wim> <out-first.swm> <sizeMiB>"); exit(2)
    }
    do {
        var last = 0
        let paths = try WimSplitter.split(wimPath: args[2], firstPartPath: args[3], maxPartSize: mib * 1024 * 1024) { p in
            if p.partNumber != last { last = p.partNumber; print("  writing part \(p.partNumber)/\(p.totalParts)…") }
        }
        print("✅ wrote \(paths.count) part(s):"); paths.forEach { print("   \($0)") }
        exit(0)
    } catch { err("split error: \(error)"); exit(1) }

case "probe":
    guard args.count >= 3 else { err("usage: WimTool probe <iso-path-or-url>"); exit(2) }
    let target = args[2]
    do {
        let base: ByteSource = (target.hasPrefix("http://") || target.hasPrefix("https://"))
            ? try HTTPByteSource(url: target)
            : try FileByteSource(path: target)
        let (name, extents) = try UDFReader.installImageExtents(in: base)
        let wimBytes = extents.reduce(UInt64(0)) { $0 + $1.length }
        print("Located sources/\(name) in the ISO (\(human(wimBytes)), \(extents.count) extent(s)).")
        print("Reading only the header + XML + blob table — not the payload.\n")
        let mapped = MappedByteSource(base: base, extents: extents)
        if let info = try? WindowsImage.read(source: mapped) { printWindows(info) }
        do {
            exit(inspect(try WimReader.read(source: mapped)) ? 0 : 3)   // 3 = found, but not compatible
        } catch let e as WimError {
            // ESDs (version 0xE00) and solid/compressed WIMs land here.
            print("❌ Not compatible — \(e)")
            if name.hasSuffix(".esd") {
                print("   This ISO ships a solid-compressed sources/install.esd. Download the official")
                print("   ISO (with sources/install.wim) instead — Wingman can't split an ESD onto FAT32.")
            }
            exit(3)
        }
    } catch let e as UDFReader.Error {
        err("probe: \(e)"); exit(2)            // 2 = not a Windows ISO / install image not found / unsupported layout
    } catch {
        err("probe: \(error)"); exit(1)        // 1 = read/network error
    }

default:
    do {
        let src = try FileByteSource(path: args[1])
        if let info = try? WindowsImage.read(source: src) { printWindows(info) }
        exit(inspect(try WimReader.read(source: src)) ? 0 : 1)
    } catch { err("error: \(error)"); exit(1) }
}
