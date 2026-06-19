import Foundation
import WimKit

/// Mounts a Windows ISO and copies its contents — minus the oversized
/// `sources/install.wim` — onto a freshly-formatted FAT32 volume, reporting
/// byte-accurate progress.
///
/// UNPRIVILEGED by design: reading an ISO and writing a permission-less FAT
/// volume need no root, so this lives in the app rather than the daemon (least
/// privilege — the daemon only performs the disk erase). `install.wim` exceeds
/// FAT32's 4 GB limit and is handled separately by the WIM-split step.
final class MediaWriter: ObservableObject {
    @Published var isCopying = false
    @Published var progress: Double = 0      // 0...1
    @Published var currentItem: String = ""
    @Published var status: String = ""

    private static let hdiutil = "/usr/bin/hdiutil"
    private static let diskutil = "/usr/sbin/diskutil"
    // Excluded from the verbatim copy (both exceed FAT32's 4 GB limit); compared
    // case-insensitively. install.wim is split into .swm parts; install.esd is
    // unsplittable, so an ESD-only ISO is refused before we get here.
    private static let skipRelativePaths: Set<String> = ["sources/install.wim", "sources/install.esd"]
    private let queue = DispatchQueue(label: "ie.duggan.Wingman.mediawriter", qos: .userInitiated)

    private let cancelLock = NSLock()
    private var _cancelled = false
    private var cancelled: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return _cancelled }
        set { cancelLock.lock(); _cancelled = newValue; cancelLock.unlock() }
    }

    func cancel() { cancelled = true }

    /// Copy `isoURL`'s contents to the FAT32 volume on whole disk `diskBSD`
    /// (e.g. "disk4"), which the format step created. The destination is resolved
    /// from the *device*, never a volume-name guess. Runs off the main thread;
    /// observe the @Published properties.
    /// `bypassWin11Checks` requests the Windows 11 hardware-requirement bypass
    /// (TPM / Secure Boot / RAM, …). It is honored only when the ISO is NOT a
    /// confirmed Windows 10 image — re-validated here, never trusting the caller.
    func copy(isoURL: URL, toDiskBSD diskBSD: String, bypassWin11Checks: Bool = false) {
        guard !isCopying else { return }
        cancelled = false
        publish { $0.isCopying = true; $0.progress = 0; $0.currentItem = ""; $0.status = "Locating target volume…" }
        queue.async { [weak self] in self?.runCopy(isoURL: isoURL, diskBSD: diskBSD, bypassWin11Checks: bypassWin11Checks) }
    }

    private func runCopy(isoURL: URL, diskBSD: String, bypassWin11Checks: Bool) {
        // Resolve the destination from the DEVICE, never a hardcoded label: with
        // a case-insensitive /Volumes and any pre-existing "Windows" volume, the
        // new stick can mount as "/Volumes/WINDOWS 1" while a label check passes
        // against the wrong target — writing the whole tree to the wrong place.
        guard let destination = mountPoint(forFormattedDisk: diskBSD) else {
            return finish(false, cancelled ? "Cancelled."
                                           : "No mounted volume found on \(diskBSD) — format the USB first.")
        }

        guard let mount = mountISO(isoURL) else {
            return finish(false, "Failed to mount \(isoURL.lastPathComponent).")
        }
        defer { detach(mount.wholeDisk) }   // always unmount, success or failure

        // Identify the image (version + editions) — advisory, for labelling and
        // to decide whether the Win11 bypass applies below.
        let windows = windowsImage(at: mount.mountPoint)

        // We can only build from a splittable sources/install.wim. Decide this
        // from the actual files so it fails CLOSED even if the advisory XML parse
        // failed: an ESD-only ISO is solid-compressed and can't be split onto
        // FAT32, and copying the multi-GB .esd verbatim would die at the 4 GB mark.
        let installWim = mount.mountPoint.appendingPathComponent("sources/install.wim")
        guard FileManager.default.fileExists(atPath: installWim.path) else {
            let hasEsd = FileManager.default.fileExists(atPath: mount.mountPoint.appendingPathComponent("sources/install.esd").path)
            return finish(false, hasEsd
                ? "“\(isoURL.lastPathComponent)” ships a solid-compressed sources/install.esd that can't be split onto FAT32. Download the official ISO (with sources/install.wim) instead."
                : "No sources/install.wim found on “\(isoURL.lastPathComponent)” — is this a Windows installation ISO?")
        }
        // Secondary: a .wim that is itself solid (mislabelled ESD) — clearer than
        // letting the splitter fail later. (The splitter re-checks authoritatively.)
        if let windows, !windows.isSplittable {
            return finish(false, "“\(isoURL.lastPathComponent)” contains a solid-compressed \(windows.product.rawValue) image that Wingman can't split onto FAT32. Download the official ISO (with a standard sources/install.wim) instead.")
        }

        guard let items = enumerate(at: mount.mountPoint) else {
            return finish(false, "Could not read the mounted ISO.")
        }
        let copyBytes = items.files.reduce(Int64(0)) { $0 + $1.size }
        guard copyBytes > 0 else { return finish(false, "No copyable files found on the ISO.") }

        let wimSize = ((try? FileManager.default.attributesOfItem(atPath: installWim.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let grandTotal = copyBytes + wimSize

        // Free-space pre-check for the WHOLE job (copy + split), up front.
        let free = (try? destination.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? 0
        guard Int64(free) >= grandTotal else {
            return finish(false, "\(destination.lastPathComponent) has \(Self.human(Int64(free))) free but \(Self.human(grandTotal)) is needed — use a larger USB stick.")
        }

        // Phase 1 — copy everything except install.wim.
        publish { $0.status = "Copying files (\(Self.human(copyBytes)))…" }
        let fm = FileManager.default
        for dir in items.directories {
            try? fm.createDirectory(at: destination.appendingPathComponent(dir), withIntermediateDirectories: true)
        }

        var copied: Int64 = 0
        for file in items.files {
            if cancelled { return finish(false, "Cancelled.") }
            publish { $0.currentItem = file.relativePath }
            do {
                try copyFile(from: file.url, to: destination.appendingPathComponent(file.relativePath)) { chunk in
                    copied += chunk
                    let snapshot = copied   // capture an immutable value for the main-thread closure
                    self.publish { $0.progress = min(Double(snapshot) / Double(grandTotal), 1.0) }
                    return !self.cancelled
                }
            } catch {
                return finish(false, "Failed copying \(file.relativePath): \(error.localizedDescription)")
            }
        }
        if cancelled { return finish(false, "Cancelled.") }

        // Optional — drop the Windows 11 hardware-check bypass onto the stick.
        // Applied only when requested AND the media isn't confirmed Windows 10
        // (the keys are inert on 10, and blanking its appraiser is pointless).
        // BEST-EFFORT: a bypass write failure must not sink an otherwise-good USB
        // or skip the essential install.wim split below — it's just a convenience.
        let bypassWanted = bypassWin11Checks && windows?.product != .windows10
        var bypassApplied = false
        if bypassWanted {
            do { try writeWin11Bypass(at: destination); bypassApplied = true }
            catch { /* keep going; surfaced in the final message */ }
        }

        // Phase 2 — split install.wim into <4 GiB parts straight onto the USB's sources/.
        if wimSize > 0 {
            publish { $0.status = "Splitting install.wim (\(Self.human(wimSize)))…" }
            let firstPart = destination.appendingPathComponent("sources/install.swm")
            do {
                try WimSplitter.split(wimPath: installWim.path,
                                      firstPartPath: firstPart.path,
                                      maxPartSize: 3800 * 1024 * 1024,
                                      isCancelled: { self.cancelled }) { p in
                    let done = copyBytes + Int64(p.completedBytes)
                    self.publish {
                        $0.progress = min(Double(done) / Double(grandTotal), 1.0)
                        $0.currentItem = "install.swm (part \(p.partNumber)/\(p.totalParts))"
                    }
                }
            } catch {
                if cancelled { return finish(false, "Cancelled.") }
                return finish(false, "Failed splitting install.wim: \(error.localizedDescription)")
            }
        }

        sync()   // flush buffers to the stick before declaring success

        // Eject so the stick is safe to unplug immediately. Best-effort: the USB
        // is already complete whether or not the eject succeeds.
        let label = destination.lastPathComponent
        let ejected = run(Self.diskutil, ["eject", diskBSD]).status == 0
        let tail = ejected ? "You can unplug it now." : "Eject it in Finder before unplugging."
        let product = windows?.product.rawValue ?? "Windows"
        let bypassNote: String
        if bypassApplied { bypassNote = " Hardware checks (TPM, Secure Boot, RAM) are bypassed." }
        else if bypassWanted { bypassNote = " (The hardware-check bypass couldn’t be written.)" }
        else { bypassNote = "" }
        finish(true, "“\(label)” is ready — \(product) USB created.\(bypassNote) \(tail)")
    }

    // MARK: - Windows 11 hardware-check bypass (app-side file drop)

    /// Identify the Windows image on the mounted ISO by reading `install.wim`'s
    /// (or `install.esd`'s) embedded XML — version + editions + splittability.
    private func windowsImage(at mountPoint: URL) -> WindowsImage? {
        for name in ["sources/install.wim", "sources/install.esd"] {
            let path = mountPoint.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path),
                  let src = try? FileByteSource(path: path),
                  let info = try? WindowsImage.read(source: src)
            else { continue }
            return info
        }
        return nil
    }

    /// Two pure file drops onto the FAT32 root that, together, reliably skip the
    /// Windows 11 hardware appraisal across 23H2/24H2/25H2 (the approach Rufus
    /// uses), while leaving the install itself fully interactive:
    ///  1. `autounattend.xml` — seeds the `HKLM\SYSTEM\Setup\LabConfig` bypass
    ///     keys during the windowsPE pass, before the "This PC can't run Windows
    ///     11" gate. It automates nothing else (no disk/partition/account), so
    ///     there is no risk of an unattended wipe.
    ///  2. A 0-byte `sources/appraiserres.dll` — makes the appraiser fail to load,
    ///     so checks are skipped even if the new setup engine ignores the answer
    ///     file. This belt-and-suspenders pairing is the robust part.
    private func writeWin11Bypass(at destination: URL) throws {
        let xml = destination.appendingPathComponent("autounattend.xml")
        try Self.autounattendXML.write(to: xml, atomically: true, encoding: .utf8)

        let appraiser = destination.appendingPathComponent("sources/appraiserres.dll")
        let fm = FileManager.default
        if fm.fileExists(atPath: appraiser.path) { try fm.removeItem(at: appraiser) }
        guard fm.createFile(atPath: appraiser.path, contents: Data()) else {
            throw NSError(domain: "Wingman", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not blank sources/appraiserres.dll"])
        }
    }

    /// windowsPE-pass `LabConfig` bypass for amd64 + arm64 media. Hardware checks
    /// only — deliberately no `ImageInstall`/`DiskConfiguration`/`oobeSystem`, so
    /// setup stays interactive.
    private static let autounattendXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <!-- Written by Wingman: bypasses the Windows 11 hardware-requirement checks
         (TPM 2.0, Secure Boot, RAM, storage, CPU) during Windows Setup. It does
         NOT automate disk selection, partitioning, editions, or accounts — the
         install stays fully interactive. Delete this file to install normally. -->
    <unattend xmlns="urn:schemas-microsoft-com:unattend"
              xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>5</Order><Path>reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>6</Order><Path>reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassDiskCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
          </RunSynchronous>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="arm64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>5</Order><Path>reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>6</Order><Path>reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassDiskCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>
    </unattend>
    """

    // MARK: - Volume resolution

    /// Mount point of the FAT volume on whole disk `wholeBSD` (the MBR data
    /// partition is `s1`; `s2` is tried as a fallback).
    ///
    /// The volume auto-mounts asynchronously after a format, and on a back-to-back
    /// run the device was just ejected (end of the previous run) and reformatted —
    /// so `diskutil` can briefly report a `MountPoint` whose directory isn't
    /// actually present yet (a phantom). Returning that path makes the copy try to
    /// `mkdir` it under root-owned `/Volumes` and fail with "permission denied".
    /// So: poll until a real, on-disk mount appears, mounting the partition
    /// explicitly if needed, and only ever return a path that exists.
    ///
    /// Budget is ~20 s of settling; it's polled cooperatively so a user Cancel is
    /// honored between steps. (A single `diskutil mount` can itself block on
    /// pathological media — diskutil bounds that internally — so a stalled call
    /// can briefly exceed the budget; the common post-format case resolves in ~1 s.)
    private func mountPoint(forFormattedDisk wholeBSD: String) -> URL? {
        let deadline = Date().addingTimeInterval(20)
        repeat {
            if cancelled { return nil }
            for suffix in ["s1", "s2"] {
                let part = wholeBSD + suffix
                if let url = existingMountPoint(of: part) { return url }
                if cancelled || Date() >= deadline { break }
                _ = run(Self.diskutil, ["mount", part])   // not yet mounted / phantom — force a real mount
                if let url = existingMountPoint(of: part) { return url }
            }
            if cancelled { return nil }
            Thread.sleep(forTimeInterval: 0.4)
        } while Date() < deadline
        return nil
    }

    /// The partition's current mount point — but only if that directory actually
    /// exists on disk (rejects a stale/phantom diskutil record).
    private func existingMountPoint(of partition: String) -> URL? {
        let r = run(Self.diskutil, ["info", "-plist", partition])
        guard r.status == 0, let data = r.output.data(using: .utf8),
              let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let mp = p["MountPoint"] as? String, !mp.isEmpty
        else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mp, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: mp, isDirectory: true)
    }

    // MARK: - hdiutil

    private struct Mount { let mountPoint: URL; let wholeDisk: String }

    private func mountISO(_ iso: URL) -> Mount? {
        let r = run(Self.hdiutil, ["attach", "-plist", "-nobrowse", "-readonly", "-noverify", iso.path])
        guard r.status == 0, let data = r.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let volume = entities.first(where: { $0["mount-point"] is String }),
              let mountPoint = volume["mount-point"] as? String,
              let devEntry = volume["dev-entry"] as? String
        else { return nil }
        return Mount(mountPoint: URL(fileURLWithPath: mountPoint, isDirectory: true),
                     wholeDisk: wholeDiskDev(devEntry))
    }

    private func detach(_ devNode: String) {
        if run(Self.hdiutil, ["detach", devNode]).status != 0 {
            _ = run(Self.hdiutil, ["detach", devNode, "-force"])
        }
    }

    /// "/dev/disk9s1" -> "/dev/disk9"
    private func wholeDiskDev(_ dev: String) -> String {
        if let r = dev.range(of: #"^/dev/disk[0-9]+"#, options: .regularExpression) { return String(dev[r]) }
        return dev
    }

    // MARK: - Enumeration & copy

    private struct FileItem { let url: URL; let relativePath: String; let size: Int64 }

    private func enumerate(at root: URL) -> (files: [FileItem], directories: [String])? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { return nil }
        var files: [FileItem] = []
        var dirs: [String] = []
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in en {
            guard url.path.hasPrefix(prefix) else { continue }
            let rel = String(url.path.dropFirst(prefix.count))
            let vals = try? url.resourceValues(forKeys: Set(keys))
            if vals?.isDirectory == true {
                dirs.append(rel)
            } else if !Self.skipRelativePaths.contains(rel.lowercased()) {
                files.append(FileItem(url: url, relativePath: rel, size: Int64(vals?.fileSize ?? 0)))
            }
        }
        return (files, dirs)
    }

    /// Streamed copy in 4 MB chunks. `progress` receives each chunk's byte count
    /// and returns false to abort. On abort OR error the partial destination file
    /// is removed, so a cancelled/failed copy never leaves a truncated file in the
    /// bootable tree.
    private func copyFile(from src: URL, to dst: URL, progress: (Int64) -> Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        fm.createFile(atPath: dst.path, contents: nil)

        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: dst)

        var aborted = false
        do {
            let chunkSize = 4 * 1024 * 1024
            while true {
                let data = input.readData(ofLength: chunkSize)
                if data.isEmpty { break }
                try output.write(contentsOf: data)
                if !progress(Int64(data.count)) { aborted = true; break }
            }
        } catch {
            try? output.close()
            try? fm.removeItem(at: dst)     // don't leave a partial file on error
            throw error
        }
        try? output.close()
        if aborted { try? fm.removeItem(at: dst) }   // don't leave a truncated file on cancel
    }

    // MARK: - Helpers

    private static func human(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func publish(_ change: @escaping (MediaWriter) -> Void) {
        DispatchQueue.main.async { change(self) }
    }

    private func finish(_ ok: Bool, _ message: String) {
        publish {
            $0.isCopying = false
            $0.currentItem = ""
            $0.status = (ok ? "✅ " : "❌ ") + message
            if ok { $0.progress = 1 }
        }
    }

    private func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "Failed to launch \(path): \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
