import AppKit
import SwiftUI

let modelsWindowID = "models"

func openModelsWindow(_ openWindow: OpenWindowAction) {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: modelsWindowID)
}

struct ModelsWindow: View {
    @ObservedObject var model: AppModel
    var body: some View { Text("Cleanup Models").padding(20) }
}
