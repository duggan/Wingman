import Foundation

/// Identifiers and code-signing requirements shared by the app and the daemon.
///
/// The Team ID (`PSPQTHW392`) is baked into the code requirements so that the
/// root helper will *only* accept connections from our own Developer-ID-signed
/// app, and the app will only talk to our own helper. If you fork this project,
/// change the bundle ids and Team ID to your own.
public enum HelperConstants {
    public static let teamID = "PSPQTHW392"

    public static let appBundleID = "ie.duggan.Wingman"
    public static let helperBundleID = "ie.duggan.Wingman.Helper"

    /// Mach service the daemon vends and the app connects to. Matches the
    /// `MachServices` key in the launchd plist.
    public static let machServiceName = helperBundleID

    /// Launchd plist filename inside `Contents/Library/LaunchDaemons/`, passed
    /// to `SMAppService.daemon(plistName:)`.
    public static let daemonPlistName = helperBundleID + ".plist"

    /// Requirement the *daemon* enforces on connecting clients: our app only.
    public static let clientCodeRequirement =
        "identifier \"\(appBundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""

    /// Requirement the *app* enforces on the daemon it connects to.
    public static let helperCodeRequirement =
        "identifier \"\(helperBundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
}
