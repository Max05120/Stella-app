import SwiftUI
import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate:
    NSObject,
    NSApplicationDelegate
{
    let backend =
        BackendManager()
    
    private let stellaDesktop =
            StellaDesktopController()

    private var quickAsk:
        QuickAskPanelController!

    private var voicePanel:
        VoicePanelController!

    private var hotKey:
        GlobalHotKey?

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {

        backend.start()
        stellaDesktop.show()

        quickAsk =
            QuickAskPanelController(
                backend: backend
            )

        voicePanel =
            VoicePanelController(
                backend: backend
            )

        hotKey =
            GlobalHotKey(
                keyCode:
                    UInt32(kVK_Space),

                modifiers:
                    UInt32(
                        cmdKey |
                        shiftKey
                    )
            ) {
                [weak self] in

                guard let self else {
                    return
                }

                Task { @MainActor in
                    self.voicePanel
                        .toggle()
                }
            }
    }

    func applicationWillTerminate(
        _ notification: Notification
    ) {

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
        Window(
            "Voice Test",
            id: "voice-test"
        ) {
            WhisperTestView()
        }
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
            Button("Voice Test") {
                            openWindow(id: "voice-test")
                        }
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
