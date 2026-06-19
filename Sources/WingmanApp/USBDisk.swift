import Foundation

/// A candidate target disk surfaced by `USBDiskScanner`. By construction these
/// are always whole, external, removable disks — never the internal/boot drive.
struct USBDisk: Identifiable, Hashable {
    let bsdName: String          // e.g. "disk4"
    let vendor: String
    let model: String
    let sizeBytes: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let isEjectable: Bool

    var id: String { bsdName }
    var devicePath: String { "/dev/\(bsdName)" }
    var rawDevicePath: String { "/dev/r\(bsdName)" }

    var displayName: String {
        let parts = [vendor, model]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? bsdName : parts.joined(separator: " ")
    }

    var humanSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
