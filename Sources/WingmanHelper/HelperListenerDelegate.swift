import Foundation
import WingmanShared

/// Accepts (or rejects) incoming XPC connections to the root daemon.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // SECURITY: this daemon runs as root. Only accept connections whose peer
        // satisfies our code requirement (our app, signed by our Team ID).
        // setCodeSigningRequirement validates via the kernel audit token, which —
        // unlike PID checks — cannot be spoofed by a racing process (macOS 13+).
        // It returns void and *throws* on a malformed requirement, so we refuse
        // up front if the requirement is empty (a build/config error) rather than
        // ever resume() an unprotected root connection.
        guard !HelperConstants.clientCodeRequirement.isEmpty else {
            NSLog("Wingman helper: REFUSING connection — empty client code requirement (misconfiguration).")
            return false
        }
        newConnection.setCodeSigningRequirement(HelperConstants.clientCodeRequirement)

        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}
