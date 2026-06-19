import Foundation
import WingmanShared

// Entry point for the root LaunchDaemon. launchd starts this process on demand
// when the app first connects to the Mach service declared in the launchd plist
// (Resources/Helper-Launchd.plist -> Contents/Library/LaunchDaemons/...).

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

NSLog("WingmanHelper: listening on \(HelperConstants.machServiceName) as uid \(getuid())")

// Park the main thread; XPC connections are serviced on libdispatch queues.
dispatchMain()
