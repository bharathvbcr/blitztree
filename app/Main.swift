import Sparkle
import SwiftUI

@main
struct BlitzTreeApp: App {
    /// Sparkle checks the latest GitHub release's appcast once a day,
    /// downloads the EdDSA-signed dmg and installs it when the app quits.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    init() {
        // A write to a pipe or socket whose reader has gone (an agent CLI
        // that exited before reading its prompt, a dropped connection) must
        // fail with EPIPE, not kill the app with SIGPIPE. Foundation resets
        // signal dispositions for the children it spawns, so they still see
        // the default. Subprocess also marks its own write ends NOSIGPIPE,
        // for processes that never run this (the test binaries).
        signal(SIGPIPE, SIG_IGN)
        // `BlitzTree /some/path` is a scan target, not a document to open.
        // Left to AppKit, the path becomes an open-file request and SwiftUI
        // then skips creating the main window entirely.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    }

    var body: some Scene {
        WindowGroup("BlitzTree") {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
            }
            ExportCommands()
        }

        // Cmd+, — language and custom model providers.
        Settings {
            TabView {
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gear") }
                ProvidersView()
                    .tabItem { Label("Model Providers", systemImage: "point.3.filled.connected.trianglepath.dotted") }
            }
            .frame(minHeight: 360)
        }
    }
}
