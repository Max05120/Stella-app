import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let backend = BackendManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        backend.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        backend.stop()
    }
}

@main
struct StellaApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Stella", systemImage: "sparkles") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

        Window("Stella", id: "chat") {
            ContentView()
                .environmentObject(appDelegate.backend)
        }
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.backend)
        }
    }
}


struct MenuBarView: View {

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("✦ Stella").font(.headline)
            Divider()
            Button("Open Stella") { openWindow(id: "chat") }
                .keyboardShortcut("o", modifiers: .command)
            Button("Settings...") { openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit Stella") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding()
        .frame(width: 220)
    }
}
