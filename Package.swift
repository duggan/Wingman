// swift-tools-version: 5.10
import PackageDescription
import Foundation

// The daemon is a *bare executable*, not a bundle, so its Info.plist (which
// carries CFBundleIdentifier + SMAuthorizedClients) must be embedded directly
// into the Mach-O __TEXT,__info_plist section at link time. We compute an
// absolute path from the manifest location so the linker finds it regardless
// of the build's working directory.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let helperInfoPlist = packageDir + "/Resources/Helper-Info.plist"

let package = Package(
    name: "Wingman",
    platforms: [.macOS(.v13)], // SMAppService + NSXPCConnection.setCodeSigningRequirement
    targets: [
        // Shared XPC contract + constants, linked into both the app and the daemon.
        .target(name: "WingmanShared"),

        // The privileged root LaunchDaemon (started on demand by SMAppService).
        .executableTarget(
            name: "WingmanHelper",
            dependencies: ["WingmanShared"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", helperInfoPlist,
                ])
            ]
        ),

        // The SwiftUI GUI app.
        .executableTarget(
            name: "WingmanApp",
            dependencies: ["WingmanShared", "WimKit"]
        ),

        // Pure-Swift WIM parsing/splitting (no external deps) for the install.wim
        // split, plus a small CLI (used by `make check-iso`) to inspect an image.
        .target(name: "WimKit"),
        .executableTarget(name: "WimTool", dependencies: ["WimKit"]),
        .testTarget(
            name: "WimKitTests",
            dependencies: ["WimKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
