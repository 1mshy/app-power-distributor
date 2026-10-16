import AppKit
import Observation
import PowerKit
import ServiceManagement

/// A saved limit for one app.
struct Rule: Codable, Identifiable, Hashable {
    var id = UUID()
    var target: AppTarget
    var settings: LimitSettings
    var isEnabled = true
}

struct AppRow: Identifiable {
    var app: AppInfo
    /// Averaged over the last few seconds: GPU energy is billed in bursts.
    var watts: Double
    var id: String { app.id }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var rules: [Rule] = [] {
        didSet {
            save()
            syncLimiters()
        }
    }
    var isPaused = false {
        didSet { syncLimiters() }
    }
    var showPowerInMenuBar = UserDefaults.standard.bool(forKey: Keys.showPower) {
        didSet { UserDefaults.standard.set(showPowerInMenuBar, forKey: Keys.showPower) }
    }
    private(set) var statuses: [UUID: LimiterStatus] = [:]
    private(set) var topApps: [AppRow] = []
    private(set) var macWatts: Double?
    private(set) var loginItemError: String?

    private var limiters: [UUID: Limiter] = [:] {
        didSet { updateAppNap() }
    }
    private var noNap: NSObjectProtocol?
    private let board = AppPowerBoard()
    private var recentWatts: [String: [Double]] = [:]
    private var timer: Timer?
    private var icons: [String: NSImage] = [:]

    private enum Keys {
        static let rules = "rules"
        static let showPower = "showPowerInMenuBar"
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.rules),
           let saved = try? JSONDecoder().decode([Rule].self, from: data) {
            rules = saved
        }
        syncLimiters()
    }

    func start() {
        guard timer == nil else { return }
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func tick() {
        for rule in rules {
            guard let limiter = limiters[rule.id] else { continue }
            statuses[rule.id] = limiter.tick()
        }
        var rows: [AppRow] = []
        var recent: [String: [Double]] = [:]
        for (app, usage) in board.sample(AppCatalog.runningApps()) {
            let samples = (recentWatts[app.id, default: []] + [usage.watts]).suffix(5)
            recent[app.id] = Array(samples)
            rows.append(AppRow(app: app, watts: samples.reduce(0, +) / Double(samples.count)))
        }
        recentWatts = recent
        topApps = rows.sorted { $0.watts > $1.watts }
        macWatts = SystemPowerMonitor.shared.average(over: 1)
    }

    var isThrottling: Bool { statuses.values.contains { $0.state == .throttled } }

    func status(of rule: Rule) -> LimiterStatus? { statuses[rule.id] }

    func hasRule(for app: AppInfo) -> Bool {
        rules.contains { $0.target.bundlePath == app.bundlePath }
    }

    // MARK: - Editing

    func addRule(for target: AppTarget) {
        if let index = rules.firstIndex(where: { $0.target.bundlePath == target.bundlePath && target.bundlePath != nil }) {
            rules[index].isEnabled = true
            return
        }
        rules.append(Rule(target: target, settings: LimitSettings(capKind: .macPower, capValue: 60)))
    }

    func chooseAppToLimit() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Limit"
        panel.message = "Choose an app to limit. The limit applies whenever it runs."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addRule(for: AppTarget(
            name: url.deletingPathExtension().lastPathComponent,
            bundleID: Bundle(url: url)?.bundleIdentifier,
            bundlePath: url.path
        ))
    }

    func removeRule(_ id: UUID) {
        rules.removeAll { $0.id == id }
    }

    // MARK: - Limiters

    private func syncLimiters() {
        let active = isPaused ? [] : rules.filter(\.isEnabled)
        let activeIDs = Set(active.map(\.id))
        for (id, limiter) in limiters where !activeIDs.contains(id) {
            limiter.stop()
            limiters[id] = nil
            statuses[id] = nil
        }
        for rule in active {
            if let limiter = limiters[rule.id], limiter.target == rule.target {
                limiter.update(settings: rule.settings)
            } else {
                limiters[rule.id]?.stop()
                limiters[rule.id] = Limiter(target: rule.target, settings: rule.settings)
            }
        }
    }

    /// App Nap would slow this app's timers and its run/pause thread, so it's off
    /// while any limit is being enforced.
    private func updateAppNap() {
        if limiters.isEmpty, let activity = noNap {
            ProcessInfo.processInfo.endActivity(activity)
            noNap = nil
        } else if !limiters.isEmpty && noNap == nil {
            noNap = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Enforcing app power limits"
            )
        }
    }

    /// Resumes everything. Called on quit.
    func stopAll() {
        for limiter in limiters.values { limiter.stop() }
        limiters.removeAll()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: Keys.rules)
        }
    }

    // MARK: - Login item

    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Icons

    func icon(for target: AppTarget) -> NSImage {
        let key = target.bundlePath ?? target.name
        if let icon = icons[key] { return icon }
        let icon: NSImage
        if let path = target.bundlePath, FileManager.default.fileExists(atPath: path) {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else {
            icon = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        }
        icons[key] = icon
        return icon
    }
}
