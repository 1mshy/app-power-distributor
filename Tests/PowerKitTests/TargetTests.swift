import Foundation
import Testing
@testable import PowerKit

struct TargetTests {
    let topaz = AppTarget(name: "Topaz Video AI", bundlePath: "/Applications/Topaz Video AI.app")
    let main = "/Applications/Topaz Video AI.app/Contents/MacOS/Topaz Video AI"
    let ffmpeg = "/Applications/Topaz Video AI.app/Contents/MacOS/ffmpeg"

    /// Coalition 50 is Topaz's (led by pid 100); coalition 7 is a terminal's (led by 10).
    var table: ProcessTable {
        ProcessTable([
            ProcessEntry(pid: 1, ppid: 0, name: "launchd", path: "/sbin/launchd", coalition: 1),
            ProcessEntry(pid: 10, ppid: 1, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", coalition: 7),
            ProcessEntry(pid: 11, ppid: 10, name: "zsh", path: "/bin/zsh", coalition: 7),
            ProcessEntry(pid: 100, ppid: 1, name: "Topaz Video AI", path: main, coalition: 50, startMicros: 5),
            ProcessEntry(pid: 101, ppid: 100, name: "ffmpeg", path: ffmpeg, coalition: 50),
            ProcessEntry(pid: 102, ppid: 100, name: "sh", path: "/bin/sh", coalition: 50),
            ProcessEntry(pid: 103, ppid: 102, name: "helper", path: "/usr/bin/helper", coalition: 50),
            ProcessEntry(pid: 104, ppid: 1, name: "MTLCompilerService", path: "/System/Library/MTLCompilerService", coalition: 50),
            ProcessEntry(pid: 200, ppid: 11, name: "ffmpeg", path: ffmpeg, coalition: 7, startMicros: 9),
            ProcessEntry(pid: 201, ppid: 200, name: "cat", path: "/bin/cat", coalition: 7),
        ])
    }

    let leaders: [UInt64: pid_t] = [1: 1, 7: 10, 50: 100]

    @Test func appFromTheDockOwnsItsCoalition() {
        let resolved = topaz.resolve(in: table, excluding: [], leaderOf: { leaders[$0] })
        #expect(resolved.coalitions == [50])
        #expect(resolved.mainPID == 100)
        #expect(resolved.pids.isSuperset(of: [100, 101, 102, 103, 104]))
    }

    @Test func aTerminalIsNeverPulledIn() {
        let resolved = topaz.resolve(in: table, excluding: [], leaderOf: { leaders[$0] })
        // The ffmpeg started from the shell is inside the bundle, so it counts, with its
        // child; the terminal and shell around it don't.
        #expect(resolved.pids.isSuperset(of: [200, 201]))
        #expect(resolved.pids.isDisjoint(with: [1, 10, 11]))
        #expect(resolved.loosePIDs == [200, 201])
    }

    @Test func excludedProcessesStayOut() {
        let resolved = topaz.resolve(in: table, excluding: [101], leaderOf: { leaders[$0] })
        #expect(!resolved.pids.contains(101))
    }

    @Test func processNameTargets() {
        let resolved = AppTarget.process(named: "FFMPEG").resolve(in: table, excluding: [], leaderOf: { leaders[$0] })
        #expect(resolved.pids == [101, 200, 201])
        #expect(resolved.coalitions.isEmpty)
    }

    @Test func nothingRunning() {
        let target = AppTarget(name: "Other", bundlePath: "/Applications/Other.app")
        #expect(target.resolve(in: table, excluding: [], leaderOf: { leaders[$0] }) == .empty)
    }

    @Test func bundlePathMustMatchWholeComponents() {
        let target = AppTarget(name: "Topaz Video", bundlePath: "/Applications/Topaz Video.app")
        #expect(target.resolve(in: table, excluding: [], leaderOf: { leaders[$0] }).isEmpty)
    }

    @Test func meteringCoversEachProcessOnce() {
        let resolved = topaz.resolve(in: table, excluding: [], leaderOf: { leaders[$0] })
        let entities = resolved.meteredEntities(in: table)
        #expect(entities.contains(.coalition(50)))
        #expect(entities.contains(.process(ProcessKey(pid: 200, startMicros: 9))))
        #expect(entities.count == 3)
    }
}

struct EnergyTrackerTests {
    @Test func turnsCountersIntoRates() {
        var now = 0.0
        var counters = Counters(cpuNanos: 0, cpuEnergy: 0, gpuNanos: 0, gpuEnergy: 0, aneEnergy: 0)
        let tracker = EnergyTracker(read: { _ in counters }, clock: { now })
        #expect(tracker.update([.coalition(1)]).isEmpty)

        now = 2
        counters = Counters(cpuNanos: 3e9, cpuEnergy: 20e9, gpuNanos: 1e9, gpuEnergy: 60e9, aneEnergy: 2e9)
        let usage = tracker.update([.coalition(1)])[.coalition(1)]
        #expect(usage?.cpuWatts == 10)
        #expect(usage?.gpuWatts == 30)
        #expect(usage?.aneWatts == 1)
        #expect(usage?.watts == 41)
        #expect(usage?.cpuPercent == 150)
        #expect(usage?.gpuPercent == 50)
    }

    @Test func skipsCountersThatWentBackwards() {
        var now = 0.0
        var energy = 50e9
        let tracker = EnergyTracker(read: { _ in Counters(cpuEnergy: energy) }, clock: { now })
        _ = tracker.update([.coalition(1)])
        now = 1
        energy = 1e9
        #expect(tracker.update([.coalition(1)]).isEmpty)
    }
}

struct AppMatchingTests {
    let apps = [
        AppInfo(name: "Topaz Video AI", bundleID: "com.topazlabs.TopazVideoAI", bundlePath: "/Applications/Topaz Video AI.app"),
        AppInfo(name: "Topaz Video", bundleID: "com.topazlabs.TopazVideo", bundlePath: "/Applications/Topaz Video.app"),
        AppInfo(name: "Topaz Gigapixel AI", bundleID: "com.topazlabs.gigapixel", bundlePath: "/Applications/Topaz Gigapixel AI.app"),
        AppInfo(name: "Safari", bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app"),
    ]

    @Test func exactNameWins() {
        let result = AppCatalog.bestMatches(for: "topaz video", in: apps)
        #expect(result.matches.map(\.name) == ["Topaz Video"])
        #expect(result.exact)
    }

    @Test func bundleIDMatches() {
        #expect(AppCatalog.bestMatches(for: "com.apple.safari", in: apps).matches.map(\.name) == ["Safari"])
    }

    @Test func vagueQueriesAreAmbiguous() {
        let result = AppCatalog.bestMatches(for: "Topaz", in: apps)
        #expect(result.matches.count == 3)
        #expect(!result.exact)
    }

    @Test func substringsAreTheLastResort() {
        #expect(AppCatalog.bestMatches(for: "gigapixel", in: apps).matches.map(\.name) == ["Topaz Gigapixel AI"])
        #expect(AppCatalog.bestMatches(for: "nothing", in: apps).matches.isEmpty)
    }
}

extension AppInfo {
    init(name: String, bundleID: String?, bundlePath: String) {
        self.init(name: name, bundleID: bundleID, bundlePath: bundlePath, pid: nil)
    }
}

struct LimitSettingsTests {
    @Test func savesAndRestoresSeveralLimits() throws {
        let settings = LimitSettings(limits: [.gpu: 50, .cpu: 300, .macPower: 60], spareMainProcess: true)
        let data = try JSONEncoder().encode(settings)
        #expect(String(decoding: data, as: UTF8.self).contains("\"gpu\":50"))
        #expect(try JSONDecoder().decode(LimitSettings.self, from: data) == settings)
    }

    @Test func summaryListsLimitsInAFixedOrder() {
        let settings = LimitSettings(limits: [.gpu: 50, .cpu: 300, .macPower: 60], efficiencyCoresOnly: true)
        #expect(settings.summary == "Mac power ≤ 60 W · CPU ≤ 300% · GPU ≤ 50% · E-cores only")
        #expect(LimitSettings().summary == "No limit")
    }
}
