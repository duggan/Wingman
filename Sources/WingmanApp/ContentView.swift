import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Combine
import WimKit

struct ContentView: View {
    @StateObject private var client = HelperClient()
    @StateObject private var scanner = USBDiskScanner()
    @StateObject private var writer = MediaWriter()

    @State private var isoURL: URL?
    @State private var selection: USBDisk.ID?
    @State private var showISOImporter = false
    @State private var confirmCreate = false
    @State private var pendingDisk: USBDisk?

    // Auto-detected from the chosen ISO (best-effort, off the main thread).
    @State private var detected: WindowsImage?
    @State private var detecting = false
    @State private var bypassChecks = false
    @State private var allowLocalAccount = false

    private var selectedDisk: USBDisk? { scanner.disks.first { $0.id == selection } }
    private var isRunning: Bool { client.isBusy || writer.isCopying }
    /// A solid ESD can't be split onto FAT32; block creation when we know that.
    private var usable: Bool { detected?.isSplittable ?? true }
    private var canCreate: Bool { client.isEnabled && isoURL != nil && selectedDisk != nil && usable && !isRunning }
    /// The bypass is a Windows 11 concern; hide it for confirmed Windows 10 media.
    private var showsBypass: Bool { isoURL != nil && detected?.product != .windows10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if !client.isEnabled { permissionBanner }
            isoStep
            usbStep
            Divider()
            createBar
            if isRunning || !statusLine.isEmpty { statusArea }
        }
        .padding(22)
        // A DEFINITE size is what lets .windowResizability(.contentSize) actually
        // fit the window to the content (and re-fit as the banner / detection line
        // / bypass toggle appear). With a flexible width it silently gives up,
        // leaving the window manually resizable and too short to show the button.
        .frame(width: 516, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            scanner.start()
            client.registerIfNeeded()
        }
        .onDisappear { scanner.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            client.refreshStatus()   // re-check the moment the user returns from System Settings
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            if !client.isEnabled { client.refreshStatus() }   // auto-detect approval, no button needed
        }
        .fileImporter(
            isPresented: $showISOImporter,
            allowedContentTypes: [UTType(filenameExtension: "iso"), .diskImage].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result { isoURL = urls.first; detectWindows() }
        }
        .confirmationDialog(
            "Erase “\(pendingDisk?.displayName ?? "")” and create a \(detected?.product.rawValue ?? "Windows") installer?",
            isPresented: $confirmCreate,
            titleVisibility: .visible
        ) {
            Button("Erase and Create", role: .destructive) { startCreate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let d = pendingDisk {
                Text("This permanently erases everything on \(d.displayName) (\(d.humanSize), \(d.devicePath)).")
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Wingman").font(.largeTitle.bold())
                Text("Create a bootable Windows 10 or 11 USB installer.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let logo = Self.logoImage {
                logo
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The Wingman mark (transparent PNG bundled in the app's Resources).
    private static let logoImage: Image? = {
        guard let url = Bundle.main.url(forResource: "wingman-logo", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: img)
    }()

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Wingman needs permission to format USB drives.").fontWeight(.medium)
                Text("Approve “Wingman” under System Settings ▸ General ▸ Login Items & Extensions — it’s detected automatically.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { client.openLoginItemsSettings() }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var isoStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Windows ISO", systemImage: "opticaldisc").font(.headline)
            HStack {
                Button("Choose ISO…") { showISOImporter = true }.disabled(isRunning)
                Text(isoURL?.lastPathComponent ?? "No ISO selected")
                    .foregroundStyle(isoURL == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if isoURL != nil { detectionLine }
            HStack(spacing: 6) {
                Text("Don’t have one?").font(.caption).foregroundStyle(.secondary)
                Button("Download Windows 11…") { open("https://www.microsoft.com/software-download/windows11") }
                    .buttonStyle(.link).font(.caption)
                Text("·").font(.caption).foregroundStyle(.secondary)
                Button("Windows 10…") { open("https://www.microsoft.com/software-download/windows10") }
                    .buttonStyle(.link).font(.caption)
            }
            if showsBypass {
                bypassToggle
                localAccountToggle
            }
        }
    }

    @ViewBuilder private var detectionLine: some View {
        if detecting {
            Label("Identifying…", systemImage: "magnifyingglass")
                .font(.caption).foregroundStyle(.secondary)
        } else if let d = detected, !d.isSplittable {
            Label("\(d.product.rawValue) install.esd — solid-compressed and can’t be split onto FAT32. Use the official ISO with install.wim.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else if let d = detected {
            Label(d.summary, systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var bypassToggle: some View {
        Toggle(isOn: $bypassChecks) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Bypass Windows 11 hardware requirements")
                Text("Skips the TPM 2.0, Secure Boot, RAM and CPU checks so Windows 11 installs on unsupported PCs. Adds an autounattend.xml; setup stays interactive.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(isRunning)
        .padding(.top, 4)
    }

    private var localAccountToggle: some View {
        Toggle(isOn: $allowLocalAccount) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Allow a local account (skip the Microsoft sign-in)")
                Text("Re-enables the “I don’t have internet” / local-account path in Windows Setup. You still create the account during install — nothing is stored on the USB. May stop working on a future Windows build.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(isRunning)
        .padding(.top, 2)
    }

    private var usbStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("USB drive", systemImage: "externaldrive").font(.headline)
            if scanner.disks.isEmpty {
                Text("Plug in a USB drive — the list updates automatically.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .center)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            } else {
                List(scanner.disks, selection: $selection) { disk in
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive.fill").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(disk.displayName).fontWeight(.medium)
                            Text("\(disk.humanSize) · \(disk.devicePath)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(disk.id)
                }
                .frame(height: 116)
                .disabled(isRunning)
            }
            Text("Only external, removable drives appear here — your internal and startup disks can’t.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var createBar: some View {
        HStack(spacing: 12) {
            Button {
                pendingDisk = selectedDisk
                confirmCreate = true
            } label: {
                Label("Create Windows USB", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!canCreate)

            if writer.isCopying {
                Button("Cancel", role: .cancel) { writer.cancel() }.controlSize(.large)
            }
        }
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if writer.isCopying {
                ProgressView(value: writer.progress) {
                    Text(writer.currentItem.isEmpty ? "Working…" : writer.currentItem)
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                }
            } else if client.isBusy {
                ProgressView { Text("Formatting…").font(.caption) }
            }
            if !statusLine.isEmpty {
                Text(statusLine)
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    /// Whichever phase is active owns the status line.
    private var statusLine: String {
        client.isBusy ? client.status : (writer.status.isEmpty ? client.status : writer.status)
    }

    // MARK: - Flow

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    private func startCreate() {
        guard let iso = isoURL, let disk = pendingDisk else { return }
        let bypass = showsBypass && bypassChecks
        let localAccount = showsBypass && allowLocalAccount
        client.formatDisk(disk) { ok in
            if ok { writer.copy(isoURL: iso, toDiskBSD: disk.bsdName, bypassWin11Checks: bypass, allowLocalAccount: localAccount) }
        }
    }

    /// Identify the chosen ISO (Windows 10 vs 11, editions, splittability) by
    /// reading just its `install.wim`/`.esd` XML via the UDF locator — no mount,
    /// no privileges, a few KB read. Best-effort: on failure the UI stays generic.
    private func detectWindows() {
        detected = nil
        bypassChecks = false
        allowLocalAccount = false
        guard let iso = isoURL else { return }
        detecting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let info = Self.readWindows(iso)
            DispatchQueue.main.async {
                guard isoURL == iso else { return }   // a newer pick won the race
                detecting = false
                detected = info
            }
        }
    }

    private static func readWindows(_ iso: URL) -> WindowsImage? {
        guard let base = try? FileByteSource(path: iso.path),
              let located = try? UDFReader.installImageExtents(in: base)
        else { return nil }
        return try? WindowsImage.read(source: MappedByteSource(base: base, extents: located.extents))
    }
}

#Preview {
    ContentView()
}
