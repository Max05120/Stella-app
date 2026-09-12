import SwiftUI
import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate:
    NSObject,
    NSApplicationDelegate
{

    // MARK: - Core services

    let backend =
        BackendManager()

    private lazy var voiceManager =
        VoiceConversationManager(
            backend: backend
        )

    private lazy var stellaDesktop =
        StellaDesktopController(
            voiceManager: voiceManager
        )

    private var quickAsk:
        QuickAskPanelController!


    // MARK: - App lifecycle

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {

        backend.start()

        quickAsk =
            QuickAskPanelController(
                backend: backend
            )

        // StellaDesktopView now owns the
        // wake-word / voice interaction surface.
        stellaDesktop.show()
    }


    func applicationWillTerminate(
        _ notification: Notification
    ) {

        voiceManager
            .stopConversation()

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
//            WhisperTestView()
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
//        .padding()
        .frame(width: 220)
    }
}
