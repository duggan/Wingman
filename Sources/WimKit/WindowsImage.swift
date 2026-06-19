import Foundation

/// Windows version + edition metadata, read from a WIM/ESD's embedded XML
/// resource. The XML lives at the `xmlData` resource header (WIM header offset
/// 72) and, in retail Windows media, is stored UNCOMPRESSED as UTF-16LE (with a
/// BOM) — so we can read it over any `ByteSource` (local file or HTTP range)
/// with no codec, the same ~few-KB read the ISO probe already does.
///
/// This deliberately does NOT go through `WimReader`: it tolerates both the
/// standard non-solid WIM (version 0x10D00) and the solid-compressed ESD
/// (version 0xE00) layouts, whose 208-byte header field offsets are identical.
/// That lets Wingman *describe* an ESD (version, editions) even though it can't
/// *split* one — surfacing a clear "use the .wim ISO" message instead of failing.
public struct WindowsImage: Equatable {
    public enum Product: String, Equatable {
        case windows10 = "Windows 10"
        case windows11 = "Windows 11"
        case unknown   = "Windows"
    }

    public struct Edition: Equatable {
        public let index: Int
        public let name: String          // <NAME>, e.g. "Windows 11 Pro"
        public let displayName: String   // <DISPLAYNAME>; falls back to name
        public let editionID: String     // <EDITIONID>, e.g. "Professional"
    }

    public let product: Product
    public let build: Int                // OS build (e.g. 19041, 26200); 0 if unknown
    public let editions: [Edition]
    public let wimVersion: UInt32
    /// Whether Wingman's pure-Swift splitter can handle this image. False for a
    /// solid-compressed ESD (version 0xE00), which would need an LZMS decoder.
    public var isSplittable: Bool { wimVersion == Self.WIM_VERSION_DEFAULT }

    public var summary: String {
        let n = editions.count
        let head = build > 0 ? "\(product.rawValue) (build \(build))" : product.rawValue
        return n > 0 ? "\(head) · \(n) edition\(n == 1 ? "" : "s")" : head
    }

    public static let WIM_VERSION_DEFAULT: UInt32 = 0x0001_0D00   // standard non-solid WIM
    public static let WIM_VERSION_SOLID:   UInt32 = 0x0000_0E00   // solid-capable ESD

    /// The Win11 21H2 RTM build; anything at or above is Windows 11.
    static let windows11MinBuild = 22000
    static let magic: [UInt8] = [0x4D, 0x53, 0x57, 0x49, 0x4D, 0x00, 0x00, 0x00]  // "MSWIM\0\0\0"

    public enum DetectError: Error, CustomStringConvertible {
        case badMagic
        case compressedXML
        case noXML
        public var description: String {
            switch self {
            case .badMagic:      return "not a WIM file (bad magic)"
            case .compressedXML: return "WIM XML resource is compressed (unexpected for retail media)"
            case .noXML:         return "WIM has no XML resource to read version from"
            }
        }
    }

    /// Read version + editions from a WIM/ESD's XML resource via `source`.
    public static func read(source: ByteSource) throws -> WindowsImage {
        let h = try source.read(at: 0, count: 208)
        guard h.count == 208, Array(h[0..<8]) == magic else { throw DetectError.badMagic }
        let version = u32(h, 12)

        // xmlData reshdr at offset 72: 7-byte size_in_wim, 1-byte flags, 8-byte
        // offset_in_wim, 8-byte uncompressed_size.
        let xmlSize = uLE(h, 72, 7)
        let xmlFlags = h[79]
        let xmlOffset = uLE(h, 80, 8)
        guard xmlFlags & 0x04 == 0 else { throw DetectError.compressedXML }   // 0x04 = COMPRESSED
        guard xmlSize > 0 else { throw DetectError.noXML }

        let fileSize = source.size
        let cap: UInt64 = 64 * 1024 * 1024
        guard xmlOffset <= fileSize, xmlSize <= fileSize - xmlOffset, xmlSize <= cap else {
            throw DetectError.noXML
        }
        let xml = decodeUTF16LE(try source.read(at: xmlOffset, count: Int(xmlSize)))

        let editions = parseEditions(xml)
        let build = firstInt(of: "BUILD", in: Substring(xml)) ?? 0
        let names = editions.map { $0.displayName.lowercased() } + editions.map { $0.name.lowercased() }

        let product: Product
        if build >= windows11MinBuild { product = .windows11 }
        else if build > 0 { product = .windows10 }
        else if names.contains(where: { $0.contains("windows 11") }) { product = .windows11 }
        else if names.contains(where: { $0.contains("windows 10") }) { product = .windows10 }
        else { product = .unknown }

        return WindowsImage(product: product, build: build, editions: editions, wimVersion: version)
    }

    // MARK: - XML scanning (lightweight; the WIM descriptor is small, flat, uppercase-tagged)

    private static func parseEditions(_ xml: String) -> [Edition] {
        var out: [Edition] = []
        var fallback = 0
        for block in imageBlocks(xml) {
            fallback += 1
            let name = tagValue("NAME", in: block) ?? ""
            let display = tagValue("DISPLAYNAME", in: block) ?? name
            let editionID = tagValue("EDITIONID", in: block) ?? ""
            let index = indexAttr(block) ?? fallback
            out.append(Edition(index: index, name: name, displayName: display, editionID: editionID))
        }
        return out
    }

    /// Substrings spanning each `<IMAGE …> … </IMAGE>` element.
    private static func imageBlocks(_ xml: String) -> [Substring] {
        var blocks: [Substring] = []
        var from = xml.startIndex
        while let open = xml.range(of: "<IMAGE", range: from..<xml.endIndex) {
            guard let close = xml.range(of: "</IMAGE>", range: open.upperBound..<xml.endIndex) else { break }
            blocks.append(xml[open.lowerBound..<close.upperBound])
            from = close.upperBound
        }
        return blocks
    }

    /// Value between `<TAG>` and `</TAG>` (first occurrence). Tags are exact, so
    /// `<NAME>` never matches `<DISPLAYNAME>`.
    private static func tagValue(_ tag: String, in s: Substring) -> String? {
        guard let open = s.range(of: "<\(tag)>"),
              let close = s.range(of: "</\(tag)>", range: open.upperBound..<s.endIndex)
        else { return nil }
        return String(s[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstInt(of tag: String, in s: Substring) -> Int? {
        tagValue(tag, in: s).flatMap { Int($0) }
    }

    /// The integer in `INDEX="n"` on an `<IMAGE>` open tag.
    private static func indexAttr(_ block: Substring) -> Int? {
        guard let r = block.range(of: "INDEX=\"") else { return nil }
        let digits = block[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private static func decodeUTF16LE(_ bytes: [UInt8]) -> String {
        var b = bytes[...]
        if b.count >= 2, b[b.startIndex] == 0xFF, b[b.startIndex + 1] == 0xFE { b = b.dropFirst(2) }  // strip BOM
        var units = [UInt16](); units.reserveCapacity(b.count / 2)
        var i = b.startIndex
        while i + 1 < b.endIndex { units.append(UInt16(b[i]) | (UInt16(b[i + 1]) << 8)); i += 2 }
        return String(decoding: units, as: UTF16.self)
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        var v: UInt32 = 0; for i in 0..<4 { v |= UInt32(b[o + i]) << (8 * i) }; return v
    }
    private static func uLE(_ b: [UInt8], _ o: Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0; for i in 0..<n { v |= UInt64(b[o + i]) << (8 * i) }; return v
    }
}
