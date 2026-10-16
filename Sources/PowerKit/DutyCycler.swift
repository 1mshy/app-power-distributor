import Darwin
import Foundation

/// Throttles a set of processes by letting them run for only part of every period:
/// SIGCONT, run for `duty * period`, SIGSTOP, wait out the rest.
///
/// Stopped processes can't issue CPU work or submit new GPU or Neural Engine work, so
/// this caps all three. Whatever happens, `stop()` resumes everything it paused.
public final class DutyCycler: @unchecked Sendable {
    private let condition = NSCondition()
    private var targets: Set<pid_t> = []
    private var paused: Set<pid_t> = []
    private var duty: Double = 1
    private var period: Double
    private var isRunning = false
    private var thread: Thread?
    private let ledgerID = SafetyNet.newOwnerID()

    public init(period: Double = 0.1) {
        self.period = Self.clampPeriod(period)
    }

    deinit { stop() }

    public func setTargets(_ pids: Set<pid_t>) {
        condition.lock()
        let dropped = paused.subtracting(pids)
        for pid in dropped { kill(pid, SIGCONT) }
        paused.subtract(dropped)
        let changed = pids != targets
        targets = pids
        condition.unlock()
        if changed { SafetyNet.record(owner: ledgerID, paused: pids) }
    }

    public func setDuty(_ value: Double) {
        condition.lock()
        duty = min(max(value, 0), 1)
        condition.unlock()
    }

    public func setPeriod(_ seconds: Double) {
        condition.lock()
        period = Self.clampPeriod(seconds)
        condition.unlock()
    }

    public func start() {
        condition.lock()
        defer { condition.unlock() }
        guard !isRunning else { return }
        isRunning = true
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "DutyCycler"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Stops cycling and resumes every process this cycler paused.
    public func stop() {
        condition.lock()
        isRunning = false
        condition.broadcast()
        resumeAll()
        condition.unlock()
        SafetyNet.clear(owner: ledgerID)
    }

    private func loop() {
        condition.lock()
        defer { condition.unlock() }
        while isRunning {
            let start = now()
            let cycle = period
            if duty >= 0.995 || targets.isEmpty {
                resumeAll()
                guard wait(until: start + cycle) else { break }
                continue
            }
            resumeAll()
            guard wait(until: start + cycle * duty) else { break }
            for pid in targets where kill(pid, SIGSTOP) == 0 { paused.insert(pid) }
            guard wait(until: start + cycle) else { break }
        }
        resumeAll()
    }

    // The helpers below are called with the condition's lock held.

    private func resumeAll() {
        for pid in paused { kill(pid, SIGCONT) }
        paused.removeAll()
    }

    /// Waits until `deadline` (uptime seconds). Returns false if stopped meanwhile.
    private func wait(until deadline: Double) -> Bool {
        while isRunning {
            let remaining = deadline - now()
            if remaining <= 0 { return true }
            _ = condition.wait(until: Date(timeIntervalSinceNow: remaining))
        }
        return false
    }

    private func now() -> Double { EnergyTracker.uptime() }

    private static func clampPeriod(_ seconds: Double) -> Double { min(max(seconds, 0.02), 2) }
}

/// Moves processes onto the efficiency cores ("darwin background" policy: E-cores only,
/// lowest disk and network priority), and undoes it.
public final class EfficiencyCorePolicy {
    public private(set) var applied: Set<pid_t> = []
    private let ledgerID = SafetyNet.newOwnerID()

    public init() {}

    deinit { clear() }

    public func apply(to pids: Set<pid_t>) {
        for pid in applied.subtracting(pids) { setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0) }
        for pid in pids.subtracting(applied) { setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG) }
        if pids != applied { SafetyNet.record(owner: ledgerID, background: pids) }
        applied = pids
    }

    public func clear() {
        apply(to: [])
        SafetyNet.clear(owner: ledgerID)
    }
}
