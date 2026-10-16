import Darwin
import Foundation
import CProbes
import Testing
@testable import PowerKit

/// End-to-end tests against a real busy process: a renamed copy of power-burn, so
/// nothing else on the machine matches its name.
@Suite(.serialized)
final class ThrottlingTests {
    let name = "apd-spin-\(getpid())"
    let process = Process()

    init() throws {
        // The test binary sits in PowerKitTests.xctest/Contents/MacOS, beside the products.
        var image = Dl_info()
        dladdr(#dsohandle, &image)
        var products = URL(fileURLWithPath: String(cString: image.dli_fname))
        while products.pathExtension != "xctest" && products.path != "/" { products.deleteLastPathComponent() }
        products.deleteLastPathComponent()
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: products.appendingPathComponent("power-burn"), to: copy)
        process.executableURL = copy
        process.arguments = ["--cpu", "1"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        Thread.sleep(forTimeInterval: 0.3)
    }

    deinit {
        kill(process.processIdentifier, SIGCONT)
        process.terminate()
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(name))
    }

    var pid: pid_t { process.processIdentifier }

    func cpuPercent(over seconds: Double) -> Double {
        let key = ProcessKey(pid: pid, startMicros: 0)
        let before = EnergyTracker.readKernelCounters(.process(key))!.cpuNanos
        Thread.sleep(forTimeInterval: seconds)
        let after = EnergyTracker.readKernelCounters(.process(key))!.cpuNanos
        return (after - before) / 1e9 / seconds * 100
    }

    func isStopped() -> Bool { ProcessTable.snapshot()[pid]?.isStopped ?? false }

    @Test func dutyCyclingCutsCPUAndAlwaysResumes() {
        #expect(cpuPercent(over: 0.5) > 80)

        let cycler = DutyCycler(period: 0.05)
        cycler.setTargets([pid])
        cycler.setDuty(0.25)
        cycler.start()
        let throttled = cpuPercent(over: 2)
        cycler.stop()

        #expect(throttled > 12 && throttled < 40, "expected about 25%, got \(throttled)")
        #expect((0..<20).allSatisfy { _ in
            Thread.sleep(forTimeInterval: 0.01)
            return !isStopped()
        })
        #expect(cpuPercent(over: 0.5) > 80)
    }

    @Test func droppedTargetsAreResumedImmediately() {
        let cycler = DutyCycler(period: 0.2)
        cycler.setTargets([pid])
        cycler.setDuty(0.05)
        cycler.start()
        Thread.sleep(forTimeInterval: 0.5)
        cycler.setTargets([])
        Thread.sleep(forTimeInterval: 0.05)
        #expect(!isStopped())
        cycler.stop()
    }

    @Test func limiterHoldsACPUCap() {
        let limiter = Limiter(target: .process(named: name), settings: LimitSettings(capKind: .cpu, capValue: 30))
        var readings: [Double] = []
        for _ in 0..<16 {
            let status = limiter.tick()
            if let measured = status.measured { readings.append(measured) }
            Thread.sleep(forTimeInterval: 0.5)
        }
        limiter.stop()

        let settled = readings.suffix(6)
        let average = settled.reduce(0, +) / Double(settled.count)
        #expect(abs(average - 30) < 10, "settled readings \(Array(settled))")
        #expect(!isStopped())
    }

    /// Share of the process's CPU time spent on performance cores.
    func performanceCoreShare(over seconds: Double) -> Double {
        var before = apd_process_usage(), after = apd_process_usage()
        apd_process_usage_read(pid, &before)
        Thread.sleep(forTimeInterval: seconds)
        apd_process_usage_read(pid, &after)
        let total = Double(after.cpu_time_mach - before.cpu_time_mach)
        return total > 0 ? Double(after.cpu_ptime_mach - before.cpu_ptime_mach) / total : 0
    }

    @Test(.enabled(if: Self.hasEfficiencyCores))
    func efficiencyCoresAreUndone() {
        let policy = EfficiencyCorePolicy()
        policy.apply(to: [pid])
        Thread.sleep(forTimeInterval: 0.2)
        let confined = performanceCoreShare(over: 1)
        policy.clear()
        Thread.sleep(forTimeInterval: 0.2)
        let freed = performanceCoreShare(over: 1)

        #expect(confined < 0.1, "\(Int(confined * 100))% on P-cores while confined")
        #expect(freed > 0.5, "\(Int(freed * 100))% on P-cores after clearing")
    }

    static var hasEfficiencyCores: Bool {
        var levels: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.nperflevels", &levels, &size, nil, 0) == 0 && levels > 1
    }
}
