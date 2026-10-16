import AppKit
import PowerKit
import SwiftUI

@main
enum Entry {
    static func main() {
        SafetyNet.runGuardianIfRequested()
        SafetyNet.recoverAbandonedLedgers()
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), flag + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Snapshot.render(to: CommandLine.arguments[flag + 1]) }
            exit(0)
        }
        PowerDistributorApp.main()
    }
}

struct PowerDistributorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.isThrottling ? "bolt.fill" : "bolt")
                if model.showPowerInMenuBar, let watts = model.macWatts {
                    Text(String(format: "%.0f W", watts)).monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.start() }
        // `kill` and logout send SIGTERM; resume everything before going.
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { AppModel.shared.stopAll() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.stopAll() }
    }
}

/// Renders the panel to a PNG, for checking the layout without clicking the menu bar:
/// `AppPowerDistributor --snapshot out.png [--snapshot-rule <app> [seconds]]` adds a
/// temporary limit for <app> and lets it run for a few seconds first.
@MainActor
enum Snapshot {
    static func render(to path: String) {
        _ = NSApplication.shared
        let model = AppModel.shared
        let arguments = CommandLine.arguments
        var temporaryRule: UUID?
        if let flag = arguments.firstIndex(of: "--snapshot-rule"), flag + 1 < arguments.count,
           let target = try? AppCatalog.target(for: arguments[flag + 1]) {
            model.addRule(for: target)
            temporaryRule = model.rules.last?.id
        }
        let seconds = arguments.firstIndex(of: "--snapshot-rule").flatMap { $0 + 2 < arguments.count ? Int(arguments[$0 + 2]) : nil } ?? 2
        for _ in 0..<max(seconds, 2) {
            model.tick()
            Thread.sleep(forTimeInterval: 1)
        }
        model.tick()
        defer {
            if let temporaryRule { model.removeRule(temporaryRule) }
            model.stopAll()
        }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let panel = PanelView(model: model, initiallyExpanded: temporaryRule)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: panel)
            host.appearance = NSAppearance(named: appearance)
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let url = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("\(suffix).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
