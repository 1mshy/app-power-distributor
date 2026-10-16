import CProbes
import Foundation

/// Whole-Mac power draw from the SMC's PSTR sensor (watts), sampled ten times a second
/// so readings can be averaged over any interval.
public final class SystemPowerMonitor: @unchecked Sendable {
    public static let shared = SystemPowerMonitor()

    private let lock = NSLock()
    private var samples: [(time: Double, watts: Double)] = []
    private var timer: DispatchSourceTimer?
    private var available: Bool?

    /// Average over the last `seconds`, or nil if the sensor can't be read.
    public func average(over seconds: Double = 1) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        startIfNeeded()
        guard available == true else { return nil }
        let cutoff = EnergyTracker.uptime() - seconds
        let recent = samples.filter { $0.time >= cutoff }
        if recent.isEmpty { return samples.last?.watts }
        return recent.map(\.watts).reduce(0, +) / Double(recent.count)
    }

    public var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        startIfNeeded()
        return available == true
    }

    // Called with the lock held.
    private func startIfNeeded() {
        guard available == nil else { return }
        guard apd_smc_open() == 0, Self.readSensor() != nil else {
            available = false
            return
        }
        available = true
        record()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.record()
            self.lock.unlock()
        }
        timer.resume()
        self.timer = timer
    }

    // Called with the lock held.
    private func record() {
        guard let watts = Self.readSensor() else { return }
        let now = EnergyTracker.uptime()
        samples.append((now, watts))
        if let first = samples.first, now - first.time > 10 {
            samples.removeAll { now - $0.time > 10 }
        }
    }

    private static func readSensor() -> Double? {
        let value = apd_smc_read_float("PSTR")
        return value.isFinite && value >= 0 ? Double(value) : nil
    }
}
