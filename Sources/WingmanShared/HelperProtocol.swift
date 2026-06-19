import Foundation

/// The XPC interface exposed by the privileged root daemon.
///
/// Every method is *narrow and typed*. Never add a generic "runCommand" — that
/// turns the root helper into a privilege-escalation hole. The daemon
/// independently re-validates any disk target it is asked to touch; it does not
/// trust the caller's claim that a device is a safe removable USB.
@objc public protocol HelperProtocol {
    /// Erases `bsdName` (e.g. "disk4") and creates a single FAT32 volume named
    /// `volumeLabel` under the given partition `scheme` ("MBR" or "GPT").
    ///
    /// The daemon REFUSES unless `bsdName` is a whole, external,
    /// removable/ejectable disk that is not the boot disk. `reply` returns
    /// success plus the underlying `diskutil` output (or the refusal reason).
    func partitionAndFormat(
        bsdName: String,
        volumeLabel: String,
        scheme: String,
        with reply: @escaping (_ success: Bool, _ message: String) -> Void
    )
}
