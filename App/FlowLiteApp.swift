import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.start()
    }
}

@main
struct FlowLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: delegate.state)
        } label: {
            MenuBarIcon(app: delegate.state)
        }

        Window("FlowLite History", id: "history") {
            HistoryView(store: delegate.state.store)
        }
        .defaultLaunchBehavior(.suppressed)

        Window("FlowLite Settings", id: "settings") {
            SettingsView(app: delegate.state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var app: AppState

    var body: some View {
        Image(systemName: app.isReady ? "waveform" : "exclamationmark.triangle")
    }
}
