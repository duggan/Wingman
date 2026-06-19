import Foundation
import WingmanShared

/// Implements the privileged operations performed as root.
final class HelperService: NSObject, HelperProtocol {

    private static let diskutil = "/usr/sbin/diskutil"

    func partitionAndFormat(
        bsdName: String,
        volumeLabel: String,
        scheme: String,
        with reply: @escaping (Bool, String) -> Void
    ) {
        // DEFENSE IN DEPTH: re-validate the target independently of the app.
        if let refusal = Self.validateTarget(bsdName) {
            NSLog("Wingman helper: REFUSING partitionAndFormat(\(bsdName)): \(refusal)")
            reply(false, refusal)
            return
        }

        // Pin the device identity so a hot-swap between validation and erase
        // (diskN names are recycled by the kernel on replug) cannot redirect us
        // onto a different physical disk.
        guard let pinnedIdentity = Self.diskIdentity(bsdName) else {
            reply(false, "Could not fingerprint \(bsdName); aborting.")
            return
        }

        // Force-unmount the target's volumes so eraseDisk can't fail on a busy
        // stick. Safe: validateTarget already confirmed it's external removable
        // media that's about to be wiped anyway.
        _ = Self.run(Self.diskutil, ["unmountDisk", "force", bsdName])

        // Re-confirm the identity immediately before the destructive call.
        guard Self.diskIdentity(bsdName) == pinnedIdentity else {
            reply(false, "Target \(bsdName) changed between validation and erase — aborting for safety.")
            return
        }

        let label = Self.sanitizeFATLabel(volumeLabel)
        let schemeArg = (scheme.uppercased() == "GPT") ? "GPTFormat" : "MBRFormat"

        NSLog("Wingman helper: erasing \(bsdName) -> FAT32 '\(label)' (\(schemeArg))")
        let result = Self.run(Self.diskutil, ["eraseDisk", "FAT32", label, schemeArg, bsdName])

        if result.status != 0 {
            let out = result.output
            if out.lowercased().contains("could not be unmounted")
                || out.contains("-69877") || out.contains("-69888") {
                reply(false, "A volume on \(bsdName) is in use. Close any Finder windows, let indexing finish, and try again.\n\n\(out)")
                return
            }
        }
        reply(result.status == 0, result.output)
    }

    // MARK: - Safety validation

    /// Returns a refusal reason if `bsd` is not a safe removable-USB target, else nil.
    static func validateTarget(_ bsd: String) -> String? {
        // Strict shape — also blocks any path/option trickery in the identifier.
        guard bsd.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            return "Invalid disk identifier '\(bsd)'."
        }

        // Boot/system disks first, fail CLOSED if we can't determine them.
        guard let forbidden = forbiddenWholeDisks() else {
            return "Could not determine the system/boot disks; refusing for safety."
        }
        if forbidden.contains(bsd) {
            return "Refusing to erase a system/boot disk (\(bsd))."
        }

        let info = run(diskutil, ["info", "-plist", bsd])
        guard info.status == 0,
              let data = info.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return "Could not read disk info for \(bsd)."
        }
        if (plist["Error"] as? Bool) == true {
            return "diskutil reported an error for \(bsd)."
        }
        // Require the safety-relevant keys to be present Bools — refuse on ambiguity.
        guard let isWhole = plist["WholeDisk"] as? Bool,
              let isInternal = plist["Internal"] as? Bool,
              let ejectable = plist["Ejectable"] as? Bool,
              let removable = plist["RemovableMedia"] as? Bool
        else {
            return "Incomplete disk info for \(bsd); refusing for safety."
        }

        guard isWhole else { return "\(bsd) is not a whole disk." }
        guard !isInternal else { return "Refusing: \(bsd) is an internal disk." }
        // Strategy A targets removable USB media. We accept ejectable-OR-removable
        // (matching the app's picker); a fixed external SSD is still gated behind
        // the user's explicit, named confirmation in the UI.
        guard ejectable || removable else { return "Refusing: \(bsd) is not removable or ejectable." }
        return nil
    }

    /// Every whole disk that must never be erased: the disk backing "/" plus the
    /// physical disks behind its APFS container. Returns nil if it can't be
    /// computed (caller must then refuse — fail closed).
    static func forbiddenWholeDisks() -> Set<String>? {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return nil }
        let mnt = withUnsafeBytes(of: &fs.f_mntfromname) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        guard let rootWhole = wholeDiskName(of: mnt) else { return nil }
        var forbidden: Set<String> = [rootWhole]

        // Walk the APFS physical stores behind the root container (e.g. the
        // synthesized disk3 is backed by physical disk0). Each store must also
        // be protected, otherwise an external-booted Mac's real disk slips through.
        let info = run(diskutil, ["info", "-plist", rootWhole])
        if info.status == 0, let data = info.output.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let stores = plist["APFSPhysicalStores"] as? [[String: Any]] {
            for store in stores {
                if let id = store["APFSPhysicalStore"] as? String, let whole = wholeDiskName(of: id) {
                    forbidden.insert(whole)
                }
            }
        }
        return forbidden
    }

    /// "/dev/disk3s1s1" or "disk0s2" -> "disk3" / "disk0".
    static func wholeDiskName(of identifier: String) -> String? {
        let dev = identifier.replacingOccurrences(of: "/dev/", with: "")
        if let r = dev.range(of: #"^disk[0-9]+"#, options: .regularExpression) {
            return String(dev[r])
        }
        return nil
    }

    /// Stable fingerprint of a disk, to detect a hot-swap across validate→erase.
    static func diskIdentity(_ bsd: String) -> String? {
        let info = run(diskutil, ["info", "-plist", bsd])
        guard info.status == 0, let data = info.output.data(using: .utf8),
              let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let uuid = (p["DiskUUID"] as? String) ?? ""
        let media = (p["MediaName"] as? String) ?? ""
        let ioreg = (p["IORegistryEntryName"] as? String) ?? ""
        let size = (p["Size"] as? NSNumber)?.int64Value ?? (p["TotalSize"] as? NSNumber)?.int64Value ?? 0
        let id = "\(uuid)|\(media)|\(ioreg)|\(size)"
        return id == "|||0" ? nil : id
    }

    /// FAT volume labels are <=11 chars, uppercase, ASCII alphanumeric.
    static func sanitizeFATLabel(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let scalars = raw.uppercased().unicodeScalars.filter { allowed.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars).prefix(11))
        return cleaned.isEmpty ? "WINDOWS" : cleaned
    }

    // MARK: - Process

    /// Runs an executable by absolute path with an argument array (no shell, so
    /// no injection surface) and returns (exit status, combined stdout+stderr).
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return (-1, "Failed to launch \(path): \(error.localizedDescription)")
        }
        // diskutil output is small; read fully before waiting to avoid pipe stalls.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
