import Foundation

/// What a limit caps.
public enum CapKind: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    /// The whole Mac's power draw, in watts, reached by throttling only this app.
    case macPower
    /// The app's CPU + GPU + Neural Engine power, in watts.
    case appPower
    /// The app's CPU use, in percent of one core (400 = four cores).
    case cpu
    /// The app's share of GPU time, in percent.
    case gpu

    public var title: String {
        switch self {
        case .macPower: "Mac power"
        case .appPower: "App power"
        case .cpu: "CPU"
        case .gpu: "GPU"
        }
    }

    public var shortTitle: String {
        switch self {
        case .macPower: "Mac"
        case .appPower: "App"
        case .cpu: "CPU"
        case .gpu: "GPU"
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
    /// The limits that are on, in each cap's unit. Any combination works: the app is
    /// slowed down as much as the tightest one needs. Empty means only
    /// `efficiencyCoresOnly` applies.
    public var limits: [CapKind: Double]
    /// Run the app on the efficiency cores only.
    public var efficiencyCoresOnly: Bool
    /// Never pause the app's main process, so its window stays responsive. Only the
    /// helper processes (e.g. Topaz's ffmpeg workers) get throttled.
    public var spareMainProcess: Bool
    /// Length of one run/pause cycle, in seconds. Nil picks it automatically (see
    /// `Limiter.automaticPeriod`).
    public var period: Double?
    /// The smallest share of each cycle the app always gets to run.
    public var minimumDuty: Double

    public init(
        limits: [CapKind: Double] = [:], efficiencyCoresOnly: Bool = false,
        spareMainProcess: Bool = false, period: Double? = nil, minimumDuty: Double = 0.05
    ) {
        self.limits = limits
        self.efficiencyCoresOnly = efficiencyCoresOnly
        self.spareMainProcess = spareMainProcess
        self.period = period
        self.minimumDuty = minimumDuty
    }

    /// The limits that are on, in a fixed order.
    public var caps: [(kind: CapKind, limit: Double)] {
        CapKind.allCases.compactMap { kind in limits[kind].map { (kind, $0) } }
    }

    public var summary: String {
        var parts = caps.map { "\($0.kind.title) ≤ \($0.kind.formatLimit($0.limit))" }
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
        /// Running within its limits (or none set).
        case unthrottled
        /// Being paused part of the time to stay under its limits.
        case throttled
    }

    public var state: State = .notRunning
    public var processCount = 0
    public var usage: Usage?
    public var macWatts: Double?
    /// The current value of each limited quantity, in its cap's unit.
    public var readings: [CapKind: Double] = [:]
    /// The limit furthest over (or closest to) its cap: the one setting the run share.
    public var tightestCap: CapKind?
    /// Share of each cycle the app may run (1 = not throttled).
    public var duty: Double = 1
    /// Length of one run/pause cycle, in seconds.
    public var period: Double = Limiter.shortPeriod
    public var note: String?

    public init() {}
}

/// Enforces one `LimitSettings` on one `AppTarget`. Call `tick()` about once a second;
/// call `stop()` when done, which resumes everything.
public final class Limiter {
    public let target: AppTarget
    public private(set) var settings: LimitSettings
    public private(set) var status = LimiterStatus()

    /// Cycle lengths `automaticPeriod` picks between.
    public static let shortPeriod = 0.1
    public static let longPeriod = 1.0

    private let cycler: DutyCycler
    private let efficiencyCores = EfficiencyCorePolicy()
    private let tracker = EnergyTracker()
    private var controller: DutyController
    private var overCapStreak = 0
    private var gpuBound = false

    public init(target: AppTarget, settings: LimitSettings) {
        self.target = target
        self.settings = settings
        cycler = DutyCycler(period: settings.period ?? Self.shortPeriod)
        controller = DutyController(minimumDuty: settings.minimumDuty)
        if settings.limits[.macPower] != nil { _ = SystemPowerMonitor.shared.isAvailable }
    }

    deinit { stop() }

    public func update(settings new: LimitSettings) {
        guard new != settings else { return }
        // The controller works on usage relative to the limits, so it carries on from
        // the current run share whichever limits change.
        controller.minimumDuty = new.minimumDuty
        if new.limits[.macPower] != nil { _ = SystemPowerMonitor.shared.isAvailable }
        settings = new
    }

    /// The run/pause cycle length when the settings leave it automatic.
    ///
    /// GPU work an app has already queued keeps running while it's paused. A GPU-bound
    /// app queues more in a few milliseconds of run time than the GPU finishes in the
    /// rest of a short cycle: Topaz Video AI kept the GPU 100% busy while running only
    /// 7% of every 100 ms, and swung between 15% and 95% below that. In 1-second
    /// cycles the queue drains during each pause, and the same cap held at 50%, most
    /// seconds within ±5. CPU-bound apps keep short cycles, so they stutter less.
    public var automaticPeriod: Double { gpuBound ? Self.longPeriod : Self.shortPeriod }

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
            gpuBound = false
            status = next
            return next
        }

        let caps = settings.caps
        var throttled = resolved.pids
        if settings.spareMainProcess, let main = resolved.mainPID { throttled.remove(main) }
        cycler.setTargets(caps.isEmpty ? [] : throttled)
        if !caps.isEmpty { cycler.start() }
        efficiencyCores.apply(to: settings.efficiencyCoresOnly ? resolved.pids : [])

        let rates = tracker.update(resolved.meteredEntities(in: table))
        next.processCount = resolved.pids.count
        next.usage = rates.isEmpty ? nil : rates.values.reduce(Usage(), +)
        if let usage = next.usage, usage.coversGPU, usage.gpuPercent >= 50 { gpuBound = true }
        let period = settings.period ?? automaticPeriod
        cycler.setPeriod(period)
        next.period = period

        guard !caps.isEmpty else {
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

        // Each limit is measured against its cap; the one furthest over sets the pace.
        var worst = 0.0
        for (kind, limit) in caps {
            let reading: Double
            var idle = false
            switch kind {
            case .appPower:
                reading = usage.watts
            case .cpu:
                reading = usage.cpuPercent
            case .gpu:
                reading = usage.gpuPercent
                if !usage.coversGPU && resolved.coalitions.isEmpty {
                    next.note = "GPU use can't be measured for programs started from a terminal; open the app normally."
                }
            case .macPower:
                // The sensor updates about once a second and trails reality by a second
                // or two; averaging over two seconds smooths its steps.
                if let mac = SystemPowerMonitor.shared.average(over: 2) {
                    reading = mac
                    // Throttling an app that barely uses power can't bring the Mac down.
                    idle = usage.watts < max(1, 0.05 * limit)
                } else {
                    reading = usage.watts
                    next.note = "The Mac's power sensor can't be read; limiting app power instead."
                }
            }
            next.readings[kind] = reading
            guard !idle else { continue }
            let ratio = limit > 0 ? reading / limit : .infinity
            if next.tightestCap == nil || ratio > worst {
                worst = ratio
                next.tightestCap = kind
            }
        }

        controller.update(measured: worst, cap: 1, idle: next.tightestCap == nil)
        cycler.setDuty(controller.duty)
        next.duty = controller.duty
        next.state = controller.duty < 0.995 ? .throttled : .unthrottled

        let atFloor = controller.duty <= settings.minimumDuty + 0.001
        overCapStreak = atFloor && worst > 1.15 ? overCapStreak + 1 : 0
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
        gpuBound = false
        status = LimiterStatus()
    }
}
