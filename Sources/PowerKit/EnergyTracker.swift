import CProbes
import Foundation

/// Average resource use over one measurement interval.
public struct Usage: Sendable, Equatable {
    public var cpuWatts: Double = 0
    public var gpuWatts: Double = 0
    public var aneWatts: Double = 0
    /// 100 = one CPU core busy the whole interval.
    public var cpuPercent: Double = 0
    /// 100 = the GPU busy the whole interval.
    public var gpuPercent: Double = 0
    /// False when only per-process CPU counters were available (no GPU or ANE data).
    public var coversGPU = true

    public init(
        cpuWatts: Double = 0, gpuWatts: Double = 0, aneWatts: Double = 0,
        cpuPercent: Double = 0, gpuPercent: Double = 0, coversGPU: Bool = true
    ) {
        self.cpuWatts = cpuWatts
        self.gpuWatts = gpuWatts
        self.aneWatts = aneWatts
        self.cpuPercent = cpuPercent
        self.gpuPercent = gpuPercent
        self.coversGPU = coversGPU
    }

    public var watts: Double { cpuWatts + gpuWatts + aneWatts }

    public static func + (a: Usage, b: Usage) -> Usage {
        Usage(
            cpuWatts: a.cpuWatts + b.cpuWatts,
            gpuWatts: a.gpuWatts + b.gpuWatts,
            aneWatts: a.aneWatts + b.aneWatts,
            cpuPercent: a.cpuPercent + b.cpuPercent,
            gpuPercent: a.gpuPercent + b.gpuPercent,
            coversGPU: a.coversGPU && b.coversGPU
        )
    }
}

/// Raw cumulative counters, in nanoseconds and nanojoules.
public struct Counters: Sendable, Equatable {
    public var cpuNanos: Double = 0
    public var cpuEnergy: Double = 0
    public var gpuNanos: Double = 0
    public var gpuEnergy: Double = 0
    public var aneEnergy: Double = 0
    public var coversGPU = true

    public init(
        cpuNanos: Double = 0, cpuEnergy: Double = 0, gpuNanos: Double = 0,
        gpuEnergy: Double = 0, aneEnergy: Double = 0, coversGPU: Bool = true
    ) {
        self.cpuNanos = cpuNanos
        self.cpuEnergy = cpuEnergy
        self.gpuNanos = gpuNanos
        self.gpuEnergy = gpuEnergy
        self.aneEnergy = aneEnergy
        self.coversGPU = coversGPU
    }

    /// Rates from `previous` to `self` over `seconds`. Nil if a counter went backwards.
    func rate(since previous: Counters, seconds: Double) -> Usage? {
        guard seconds > 0, cpuNanos >= previous.cpuNanos, cpuEnergy >= previous.cpuEnergy,
              gpuNanos >= previous.gpuNanos, gpuEnergy >= previous.gpuEnergy, aneEnergy >= previous.aneEnergy
        else { return nil }
        return Usage(
            cpuWatts: (cpuEnergy - previous.cpuEnergy) / 1e9 / seconds,
            gpuWatts: (gpuEnergy - previous.gpuEnergy) / 1e9 / seconds,
            aneWatts: (aneEnergy - previous.aneEnergy) / 1e9 / seconds,
            cpuPercent: (cpuNanos - previous.cpuNanos) / 1e9 / seconds * 100,
            gpuPercent: (gpuNanos - previous.gpuNanos) / 1e9 / seconds * 100,
            coversGPU: coversGPU
        )
    }
}

/// What a tracker can measure.
public enum MeteredEntity: Hashable, Sendable {
    case coalition(UInt64)
    case process(ProcessKey)
}

/// Turns cumulative kernel counters into rates by remembering the last reading.
public final class EnergyTracker {
    public typealias Reader = (MeteredEntity) -> Counters?

    private let read: Reader
    private let clock: () -> Double
    private var last: [MeteredEntity: Counters] = [:]
    private var lastTime: Double?

    public init(read: @escaping Reader = EnergyTracker.readKernelCounters, clock: @escaping () -> Double = EnergyTracker.uptime) {
        self.read = read
        self.clock = clock
    }

    /// Reads `entities` and returns each one's rate since the previous call. Entities
    /// seen for the first time report nothing until the next call.
    public func update(_ entities: Set<MeteredEntity>) -> [MeteredEntity: Usage] {
        let now = clock()
        let elapsed = lastTime.map { now - $0 } ?? 0
        var current: [MeteredEntity: Counters] = [:]
        var rates: [MeteredEntity: Usage] = [:]
        for entity in entities {
            guard let counters = read(entity) else { continue }
            current[entity] = counters
            if let previous = last[entity], let rate = counters.rate(since: previous, seconds: elapsed) {
                rates[entity] = rate
            }
        }
        last = current
        lastTime = now
        return rates
    }

    /// Seconds since the last update, or nil before the first one.
    public func secondsSinceUpdate() -> Double? { lastTime.map { clock() - $0 } }

    public func reset() {
        last = [:]
        lastTime = nil
    }

    public static func uptime() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    public static func readKernelCounters(_ entity: MeteredEntity) -> Counters? {
        let machToNanos = apd_mach_to_ns()
        switch entity {
        case .coalition(let cid):
            var usage = apd_coalition_usage()
            guard apd_coalition_usage_read(cid, &usage) == 0 else { return nil }
            return Counters(
                cpuNanos: Double(usage.cpu_time_mach) * machToNanos,
                cpuEnergy: Double(usage.cpu_energy_nj),
                gpuNanos: Double(usage.gpu_time_ns),
                gpuEnergy: Double(usage.gpu_energy_nj),
                aneEnergy: Double(usage.ane_energy_nj)
            )
        case .process(let key):
            var usage = apd_process_usage()
            guard apd_process_usage_read(key.pid, &usage) == 0 else { return nil }
            return Counters(
                cpuNanos: Double(usage.cpu_time_mach) * machToNanos,
                cpuEnergy: Double(usage.cpu_energy_nj),
                coversGPU: false
            )
        }
    }
}

extension ResolvedTarget {
    /// The counters that together cover this target without double counting.
    public func meteredEntities(in table: ProcessTable) -> Set<MeteredEntity> {
        var entities = Set(coalitions.map(MeteredEntity.coalition))
        for pid in loosePIDs {
            if let entry = table[pid] { entities.insert(.process(entry.key)) }
        }
        return entities
    }
}
