import Foundation
import DiskArbitration

/// Maintains a live list of *safe* removable USB disks using DiskArbitration.
///
/// SAFETY: a disk is only surfaced if it is a whole disk **and** external
/// **and** removable/ejectable **and** is not the disk backing "/". The
/// internal or boot drive must never appear as a writable target. We gate on
/// the `Internal` + `Removable/Ejectable` description keys — never on the
/// protocol string alone (internal NVMe can present over PCI; external SSDs
/// over Thunderbolt) — plus an explicit boot-disk exclusion.
final class USBDiskScanner: ObservableObject {
    @Published private(set) var disks: [USBDisk] = []

    private var session: DASession?
    private let queue = DispatchQueue(label: "ie.duggan.Wingman.diskarb")
    private let bootDisk = USBDiskScanner.bootWholeDiskBSDName()

    func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, USBDiskScanner.onAppeared, ctx)
        DARegisterDiskDisappearedCallback(session, nil, USBDiskScanner.onDisappeared, ctx)
        DASessionSetDispatchQueue(session, queue)
    }

    func stop() {
        guard let session else { return }
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
    }

    // MARK: - C callbacks (must not capture; `self` arrives via the context ptr)

    private static let onAppeared: DADiskAppearedCallback = { disk, context in
        guard let context else { return }
        Unmanaged<USBDiskScanner>.fromOpaque(context).takeUnretainedValue().handleAppeared(disk)
    }

    private static let onDisappeared: DADiskDisappearedCallback = { disk, context in
        guard let context, let bsd = USBDiskScanner.bsdName(of: disk) else { return }
        let scanner = Unmanaged<USBDiskScanner>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { scanner.disks.removeAll { $0.bsdName == bsd } }
    }

    private func handleAppeared(_ disk: DADisk) {
        guard let bsd = USBDiskScanner.bsdName(of: disk),
              let desc = DADiskCopyDescription(disk) as? [String: Any] else { return }

        func flag(_ key: CFString, default def: Bool) -> Bool {
            (desc[key as String] as? Bool) ?? ((desc[key as String] as? NSNumber)?.boolValue ?? def)
        }

        let isWhole = flag(kDADiskDescriptionMediaWholeKey, default: false)
        let isInternal = flag(kDADiskDescriptionDeviceInternalKey, default: true)   // fail safe: assume internal
        let isRemovable = flag(kDADiskDescriptionMediaRemovableKey, default: false)
        let isEjectable = flag(kDADiskDescriptionMediaEjectableKey, default: false)

        // SAFETY GATE — anything that isn't clearly external removable media is dropped.
        guard isWhole, !isInternal, isRemovable || isEjectable, bsd != bootDisk else { return }

        let size = (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0
        let vendor = (desc[kDADiskDescriptionDeviceVendorKey as String] as? String) ?? ""
        let model = (desc[kDADiskDescriptionDeviceModelKey as String] as? String) ?? ""

        let usb = USBDisk(bsdName: bsd, vendor: vendor, model: model, sizeBytes: size,
                          isInternal: isInternal, isRemovable: isRemovable, isEjectable: isEjectable)
        DispatchQueue.main.async {
            // Replace (don't skip) any existing entry for this BSD: a USB port
            // reused across runs can hand the same bsd name to a different stick,
            // so the entry must reflect the device that's actually there now.
            self.disks.removeAll { $0.bsdName == bsd }
            self.disks.append(usb)
            self.disks.sort { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
        }
    }

    // MARK: - Helpers

    private static func bsdName(of disk: DADisk) -> String? {
        guard let cName = DADiskGetBSDName(disk) else { return nil }
        return String(cString: cName)
    }

    /// Whole-disk BSD name backing "/", e.g. "disk3s1s1" -> "disk3". Excluded as a target.
    private static func bootWholeDiskBSDName() -> String {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return "" }
        let mnt = withUnsafeBytes(of: &fs.f_mntfromname) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let dev = mnt.replacingOccurrences(of: "/dev/", with: "")
        if let r = dev.range(of: #"^disk[0-9]+"#, options: .regularExpression) {
            return String(dev[r])
        }
        return ""
    }
}
