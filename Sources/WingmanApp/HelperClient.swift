import Foundation
import ServiceManagement
import WingmanShared

/// Manages the privileged helper (register via SMAppService) and issues the
/// one privileged operation the app needs — erase + format — over XPC.
/// All @Published mutations are marshalled to the main thread.
final class HelperClient: ObservableObject {
    @Published var status: String = ""
    @Published var isEnabled: Bool = false
    @Published var isBusy: Bool = false

    private var connection: NSXPCConnection?

    private var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    }

    private func set(_ text: String? = nil, enabled: Bool? = nil, busy: Bool? = nil) {
        DispatchQueue.main.async {
            if let text { self.status = text }
            if let enabled { self.isEnabled = enabled }
            if let busy { self.isBusy = busy }
        }
    }

    // MARK: - SMAppService lifecycle

    func refreshStatus() {
        switch service.status {
        case .enabled:           set(enabled: true)
        case .requiresApproval:  set(enabled: false)
        case .notRegistered:     set(enabled: false)
        case .notFound:          set("Wingman’s helper is missing from the app bundle.", enabled: false)
        @unknown default:        set(enabled: false)
        }
    }

    /// Register the helper only if it isn't already registered, then refresh
    /// state. Re-registering an already-enabled service throws "Operation not
    /// permitted" on some macOS versions, so we guard on status and never
    /// surface a registration error — the permission banner (driven by
    /// `isEnabled`) is the user-facing source of truth.
    func registerIfNeeded() {
        if service.status == .notRegistered {
            do { try service.register() }
            catch { NSLog("Wingman: SMAppService.register() failed: \(error.localizedDescription)") }
        }
        refreshStatus()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - XPC

    /// Lazily create (and cache) a validated connection to the root daemon.
    /// Called only from the main thread; the C-style XPC handlers hop back to
    /// main before touching `connection`, so all access to it stays on main.
    private func helperProxy(onError: @escaping (Error) -> Void) -> HelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            c.setCodeSigningRequirement(HelperConstants.helperCodeRequirement) // talk only to *our* helper
            c.invalidationHandler = { [weak self] in
                DispatchQueue.main.async {
                    self?.connection = nil
                    self?.isBusy = false
                }
            }
            c.interruptionHandler = { [weak self] in
                DispatchQueue.main.async { self?.isBusy = false }
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? HelperProtocol
    }

    /// Erase `disk` and lay down a single FAT32 volume, then call `completion`
    /// on the main thread. DESTRUCTIVE — the caller must confirm with the user first.
    func formatDisk(_ disk: USBDisk,
                    label: String = "WINDOWS",
                    scheme: String = "MBR",
                    completion: @escaping (Bool) -> Void) {
        set("Erasing and formatting \(disk.displayName)…", busy: true)
        guard let proxy = helperProxy(onError: { [weak self] error in
            self?.set("Couldn’t reach the privileged helper: \(error.localizedDescription)", busy: false)
            DispatchQueue.main.async { completion(false) }
        }) else {
            set("Couldn’t reach the privileged helper.", busy: false)
            DispatchQueue.main.async { completion(false) }
            return
        }
        proxy.partitionAndFormat(bsdName: disk.bsdName, volumeLabel: label, scheme: scheme) { [weak self] ok, message in
            DispatchQueue.main.async {
                self?.isBusy = false
                if !ok { self?.status = "Couldn’t format the USB: \(message)" }
                completion(ok)
            }
        }
    }
}
