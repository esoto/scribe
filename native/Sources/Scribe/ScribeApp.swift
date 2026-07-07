import SwiftUI

@main
struct ScribeApp: App {
    var body: some Scene {
        MenuBarExtra("scribe", systemImage: "circle") {
            Text("scribe (skeleton)")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
