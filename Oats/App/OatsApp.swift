import SwiftUI
import AppKit

@main
struct OatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Windows are managed programmatically (WindowManager). The scene here
        // provides the menu bar extra and standard app menus.
        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(systemName: "waveform")
        }

        Settings {
            SettingsView()
                .environmentObject(AppState.shared)
                .environmentObject(AppState.shared.agent)
                .environmentObject(AppState.shared.store)
                .environmentObject(AppState.shared.calendar)
                .environmentObject(AppState.shared.recorder)
        }
    }
}

struct MenuBarContent: View {
    var body: some View {
        Button("Open Oats") { AppState.shared.showMainWindow() }
        Button("Ask Oats") { AppState.shared.toggleAsk() }
            .keyboardShortcut(.space, modifiers: .option)
        Button("New chat") { AppState.shared.newChatInWindow() }
        Button("Check for Updates…") { Task { await UpdateChecker.shared.check(userInitiated: true) } }
        Button(AppState.shared.recorder.isActive ? "Stop recording" : "New note") {
            if AppState.shared.recorder.isActive {
                AppState.shared.stopMeetingNote()
            } else {
                AppState.shared.startMeetingNote()
            }
        }
        .keyboardShortcut("m", modifiers: .option)
        Divider()
        Button(AppState.shared.hudVisible ? "Hide floating controls" : "Show floating controls") {
            AppState.shared.hudVisible.toggle()
        }
        Divider()
        Button("Quit Oats") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        if env["OATS_SELFTEST_AUDIO"] != nil
            || env["OATS_SELFTEST_MIC"] != nil
            || env["OATS_SELFTEST_LOGIC"] != nil {
            SelfTest.runIfRequested()
            return
        }
        NSApp.setActivationPolicy(.regular)
        AppState.shared.bootstrap()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppState.shared.showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
