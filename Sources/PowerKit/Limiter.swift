import Foundation

/// What a limit caps.
public enum CapKind: String, Codable, CaseIterable, Sendable {
    /// The app's CPU + GPU + Neural Engine power, in watts.
    case appPower
    /// The app's CPU use, in percent of one core (400 = four cores).
    case cpu
    /// The app's share of GPU time, in percent.
    case gpu
    /// The whole Mac's power draw, in watts, reached by throttling only this app.
    case macPower

    public var title: String {
        switch self {
        case .appPower: "App power"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .macPower: "Mac power"
        }
    }

    public var unit: String {
        switch self {
        case .appPower, .macPower: "W"
        case .cpu, .gpu: "%"
        }
    }

    public func format(_ value: Double) -> String {
        switch self {
        case .appPower, .macPower: Format.watts(value)
        case .cpu, .gpu: Format.percent(value)
        }
    }

    /// A limit, which is set in whole units.
    public func formatLimit(_ value: Double) -> String {
        guard value.rounded() == value else { return format(value) }
        return unit == "%" ? String(format: "%.0f%%", value) : String(format: "%.0f W", value)
    }
}

public struct LimitSettings: Codable, Hashable, Sendable {
    /// Nil means no cap: only `efficiencyCoresOnly` applies.
    public var capKind: CapKind?
    public var capValue: Double
    /// Run the app on the efficiency cores only.
    public var efficiencyCoresOnly: Bool
    /// Never pause the app's main process, so its window stays responsive. Only the
    /// helper processes (e.g. Topaz's ffmpeg workers) get throttled.
    public var spareMainProcess: Bool
    /// Length of one run/pause cycle, in seconds.
    public var period: Double
    /// The smallest share of each cycle the app always gets to run.
    public var minimumDuty: Double

    public init(
        capKind: CapKind? = .appPower, capValue: Double = 30, efficiencyCoresOnly: Bool = false,
        spareMainProcess: Bool = false, period: Double = 0.1, minimumDuty: Double = 0.05
    ) {
        self.capKind = capKind
        self.capValue = capValue
        self.efficiencyCoresOnly = efficiencyCoresOnly
        self.spareMainProcess = spareMainProcess
        self.period = period
        self.minimumDuty = minimumDuty
    }

    public var summary: String {
        var parts: [String] = []
        if let capKind { parts.append("\(capKind.title) ≤ \(capKind.formatLimit(capValue))") }
        if efficiencyCoresOnly { parts.append("E-cores only") }
        return parts.isEmpty ? "No limit" : parts.joined(separator: " · ")
    }
}

public struct LimiterStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// None of the target's processes are running.
        case notRunning
        /// Running; the first measurement isn't in yet.
        case measuring
        /// Running within the cap (or no cap set).
        case unthrottled
        /// Being paused part of the time to stay under the cap.
        case throttled
    }

    public var state: State = .notRunning
    public var processCount = 0
    public var usage: Usage?
    public var macWatts: Double?
    /// The capped quantity, in the cap's unit.
    public var measured: Double?
    /// Share of each cycle the app may run (1 = not throttled).
    public var duty: Double = 1
    public var note: String?

    public init() {}
}

/// Enforces one `LimitSettings` on one `AppTarget`. Call `tick()` about once a second;
/// call `stop()` when done, which resumes everything.
public final class Limiter {
    public let target: AppTarget
    public private(set) var settings: LimitSettings
    public private(set) var status = LimiterStatus()

    private let cycler: DutyCycler
    private let efficiencyCores = EfficiencyCorePolicy()
    private let tracker = EnergyTracker()
    private var controller: DutyController
    private var overCapStreak = 0

    public init(target: AppTarget, settings: LimitSettings) {
        self.target = target
        self.settings = settings
        cycler = DutyCycler(period: settings.period)
        controller = DutyController(minimumDuty: settings.minimumDuty)
        if settings.capKind == .macPower { _ = SystemPowerMonitor.shared.isAvailable }
    }

    deinit { stop() }

    public func update(settings new: LimitSettings) {
        guard new != settings else { return }
        if new.capKind != settings.capKind { controller.reset() }
        controller.minimumDuty = new.minimumDuty
        cycler.setPeriod(new.period)
        settings = new
    }

    @discardableResult
    public func tick() -> LimiterStatus {
        let table = ProcessTable.snapshot()
        let resolved = target.resolve(in: table)
        let interval = tracker.secondsSinceUpdate() ?? 1
        var next = LimiterStatus()
        next.macWatts = SystemPowerMonitor.shared.average(over: max(interval, 0.2))

        guard !resolved.isEmpty else {
            cycler.setTargets([])
            cycler.setDuty(1)
            efficiencyCores.apply(to: [])
            controller.reset()
            tracker.reset()
            status = next
            return next
        }

        var throttled = resolved.pids
        if settings.spareMainProcess, let main = resolved.mainPID { throttled.remove(main) }
        cycler.setTargets(settings.capKind == nil ? [] : throttled)
        if settings.capKind != nil { cycler.start() }
        efficiencyCores.apply(to: settings.efficiencyCoresOnly ? resolved.pids : [])

        let rates = tracker.update(resolved.meteredEntities(in: table))
        next.processCount = resolved.pids.count
        next.usage = rates.isEmpty ? nil : rates.values.reduce(Usage(), +)

        guard let capKind = settings.capKind else {
            cycler.setDuty(1)
            next.state = next.usage == nil ? .measuring : .unthrottled
            status = next
            return next
        }
        guard let usage = next.usage else {
            next.state = .measuring
            next.duty = controller.duty
            status = next
            return next
        }

        let measured: Double
        var idle = false
        switch capKind {
        case .appPower:
            measured = usage.watts
        case .cpu:
            measured = usage.cpuPercent
        case .gpu:
            measured = usage.gpuPercent
            if !usage.coversGPU && resolved.coalitions.isEmpty {
                next.note = "GPU use can't be measured for programs started from a terminal; open the app normally."
            }
        case .macPower:
            // The sensor updates about once a second and trails reality by a second
            // or two; averaging over two seconds smooths its steps.
            if let mac = SystemPowerMonitor.shared.average(over: 2) {
                measured = mac
                // Throttling an app that barely uses power can't bring the Mac down.
                idle = usage.watts < max(1, 0.05 * settings.capValue)
            } else {
                measured = usage.watts
                next.note = "The Mac's power sensor can't be read; limiting app power instead."
            }
        }

        controller.update(measured: measured, cap: settings.capValue, idle: idle)
        cycler.setDuty(controller.duty)
        next.measured = measured
        next.duty = controller.duty
        next.state = controller.duty < 0.995 ? .throttled : .unthrottled

        let atFloor = controller.duty <= settings.minimumDuty + 0.001
        overCapStreak = atFloor && !idle && measured > settings.capValue * 1.15 ? overCapStreak + 1 : 0
        if overCapStreak >= 5 && next.note == nil {
            next.note = settings.spareMainProcess
                ? "Still over the limit: the main process does the heavy work. Turn off “Keep window responsive”."
                : "Still over the limit at the lowest run share."
        }
        status = next
        return next
    }

    /// Resumes every paused process and takes everything off the efficiency cores.
    public func stop() {
        cycler.stop()
        efficiencyCores.clear()
        controller.reset()
        tracker.reset()
        status = LimiterStatus()
    }
}
