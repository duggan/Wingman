import SwiftUI

@main
struct WingmanApp: App {
    var body: some Scene {
        WindowGroup("Wingman") {
            // ContentView declares its own definite size (fixed width, height =
            // its content's ideal). .contentSize then fits the window to it and
            // re-fits as conditional sections appear.
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
