import SwiftUI
import FlowLiteSystem

struct MenuContent: View {
    @ObservedObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(app.statusText)
        ForEach(Permission.allCases, id: \.self) { permission in
            if app.permissions[permission] != true, !(permission == .inputMonitoring && app.hotkeyActive) {
                Button("Grant \(permission.title)…") { app.grant(permission) }
            }
        }
        if case .failed = app.modelState {
            Button("Retry loading speech model") { app.reloadModel() }
        }
        if !app.hasAPIKey {
            Button("Add Anthropic API key…") { open("settings") }
        }
        Divider()
        Toggle("Clean up with Claude", isOn: $app.cleanupEnabled)
        Button("History…") { open("history") }
        Button("Settings…") { open("settings") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit FlowLite") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ id: String) {
        NSApp.activate()
        openWindow(id: id)
        DispatchQueue.main.async {
            let title = id == "history" ? "FlowLite History" : "FlowLite Settings"
            let window = NSApp.windows.first { $0.identifier?.rawValue == id }
                ?? NSApp.windows.first { $0.title == title }
            window?.makeKeyAndOrderFront(nil)
        }
    }
}
