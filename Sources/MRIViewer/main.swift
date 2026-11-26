import AppKit
import MRICore
import SwiftUI

setvbuf(stdout, nil, _IOLBF, 0)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct MRIViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = ViewerStore()

    var body: some Scene {
        WindowGroup("MRI Viewer") {
            ContentView(store: store)
                .frame(minWidth: 900, minHeight: 600)
                .task { LaunchOptions.apply(to: store) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open DICOM Folder…") { store.openPanel() }
                    .keyboardShortcut("o")
            }
        }
    }
}

/// Launch arguments: `--open <dir>` opens a folder; `--probe` runs the in-app probe and exits.
enum LaunchOptions {
    static var args: [String] { CommandLine.arguments }
    static func value(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func apply(to store: ViewerStore) {
        if let dir = value("--open") {
            store.open(folder: URL(fileURLWithPath: dir))
        }
        if args.contains("--probe") { UIProbe.start(store) }
    }
}

if CommandLine.arguments.contains("--render-check") {
    exit(Probes.renderCheck(CommandLine.arguments))
}
MRIViewerApp.main()
