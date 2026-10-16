import Darwin
import Foundation
import PowerKit

SafetyNet.runGuardianIfRequested()
SafetyNet.recoverAbandonedLedgers()
setlinebuf(stdout)

let usage = """
apd — cap how much power, CPU or GPU one app may use.

USAGE
  apd list                          Running apps by power use
  apd limit <app> [cap] [options]   Enforce a limit until Ctrl-C
  apd watch <app>                   Show an app's power use without limiting it
  apd resume <app>                  Un-pause an app and take it off the E-cores

CAPS (combine any; the strictest one sets the pace)
  --mac-watts W    Whole-Mac power, by throttling only this app
  --watts W        App power: CPU + GPU + Neural Engine, in watts
  --cpu PCT        CPU use as in Activity Monitor, 100 = one core (400 = four cores)
  --gpu PCT        Share of GPU time, 0-100

OPTIONS
  --ecores         Run the app on the efficiency cores only (works with or without a cap)
  --keep-ui        Never pause the app's main process; throttle only its helpers
  --period MS      Run/pause cycle length (default: 1000 for GPU-heavy apps, else 100)
  --min-run PCT    Smallest share of each cycle the app always runs (default 5)
  --interval S     Seconds between measurements (default 1)

<app> is an app name (“Topaz Video AI”), bundle id, path to a .app, or process name.

EXAMPLES
  apd limit "Topaz Video AI" --mac-watts 60 --keep-ui
  apd limit "Topaz Video AI" --gpu 50 --cpu 200 --keep-ui
  apd limit ffmpeg --cpu 300 --ecores
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("apd: \(message)\n".utf8))
    exit(1)
}

/// Splits `arguments` into the app name (every word before the first option) and options.
func splitArguments(_ arguments: [String]) -> (app: String, options: [String]) {
    let firstOption = arguments.firstIndex { $0.hasPrefix("--") } ?? arguments.endIndex
    return (arguments[..<firstOption].joined(separator: " "), Array(arguments[firstOption...]))
}

func parseLimit(_ options: [String]) -> (settings: LimitSettings, interval: Double) {
    var settings = LimitSettings()
    var interval = 1.0
    var iterator = options.makeIterator()
    func number(after flag: String) -> Double {
        guard let text = iterator.next(), let value = Double(text), value >= 0 else {
            fail("\(flag) needs a number")
        }
        return value
    }
    func setCap(_ kind: CapKind, _ flag: String) {
        settings.limits[kind] = number(after: flag)
    }
    while let option = iterator.next() {
        switch option {
        case "--watts": setCap(.appPower, option)
        case "--cpu": setCap(.cpu, option)
        case "--gpu": setCap(.gpu, option)
        case "--mac-watts": setCap(.macPower, option)
        case "--ecores": settings.efficiencyCoresOnly = true
        case "--keep-ui": settings.spareMainProcess = true
        case "--period": settings.period = number(after: option) / 1000
        case "--min-run": settings.minimumDuty = min(number(after: option), 100) / 100
        case "--interval": interval = max(number(after: option), 0.2)
        default: fail("unknown option \(option)")
        }
    }
    return (settings, interval)
}

@MainActor
func resolveTarget(_ query: String) -> AppTarget {
    guard !query.isEmpty else { fail("name an app, e.g. apd limit \"Topaz Video AI\" --gpu 50") }
    do {
        return try AppCatalog.target(for: query)
    } catch {
        fail("\(error)")
    }
}

func describe(_ status: LimiterStatus, target: AppTarget, settings: LimitSettings) -> String {
    var parts = [target.name]
    switch status.state {
    case .notRunning:
        return "\(target.name) · not running, waiting for it to start…"
    case .measuring:
        parts.append("\(status.processCount) process\(status.processCount == 1 ? "" : "es") · measuring…")
    case .unthrottled, .throttled:
        guard let usage = status.usage else { break }
        let gpu = usage.coversGPU ? " · GPU \(Format.watts(usage.gpuWatts)) · ANE \(Format.watts(usage.aneWatts))" : ""
        parts.append("app \(Format.watts(usage.watts)) (CPU \(Format.watts(usage.cpuWatts))\(gpu))")
        parts.append("CPU \(Format.percent(usage.cpuPercent))")
        if usage.coversGPU { parts.append("GPU \(Format.percent(min(usage.gpuPercent, 100)))") }
    }
    if let mac = status.macWatts { parts.append("Mac \(Format.watts(mac))") }
    if !settings.limits.isEmpty {
        let reason = settings.limits.count > 1 ? status.tightestCap.map { " (\($0.title) limit)" } ?? "" : ""
        parts.append(status.state == .throttled
            ? "running \(Format.percent(status.duty * 100)) of each \(Format.seconds(status.period)) cycle\(reason)"
            : "under the limit")
    }
    if let note = status.note { parts.append(note) }
    return parts.joined(separator: " · ")
}

// MARK: - Commands

@MainActor
func runList(_ options: [String]) {
    let board = AppPowerBoard()
    let apps = AppCatalog.runningApps()
    _ = board.sample(apps)
    _ = SystemPowerMonitor.shared.isAvailable
    Thread.sleep(forTimeInterval: 1)
    let rows = board.sample(apps)

    let nameWidth = min(max(rows.map(\.app.name.count).max() ?? 3, 3), 32)
    func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        let clipped = String(text.prefix(width))
        let space = String(repeating: " ", count: max(width - clipped.count, 0))
        return left ? clipped + space : space + clipped
    }
    print(pad("APP", nameWidth, left: true), pad("POWER", 8), pad("CPU", 8), pad("GPU", 8), pad("ANE", 8), pad("CPU%", 6), pad("GPU%", 6))
    for (app, usage) in rows where usage.watts >= 0.005 || usage.cpuPercent >= 0.5 {
        print(
            pad(app.name, nameWidth, left: true), pad(Format.watts(usage.watts), 8), pad(Format.watts(usage.cpuWatts), 8),
            pad(Format.watts(usage.gpuWatts), 8), pad(Format.watts(usage.aneWatts), 8),
            pad(Format.percent(usage.cpuPercent), 6), pad(Format.percent(min(usage.gpuPercent, 100)), 6)
        )
    }
    if let mac = SystemPowerMonitor.shared.average(over: 1) {
        print("\nWhole Mac: \(Format.watts(mac))")
    }
}

@MainActor
func runResume(_ arguments: [String]) {
    let target = resolveTarget(splitArguments(arguments).app)
    let pids = target.resolve(in: ProcessTable.snapshot()).pids
    for pid in pids {
        kill(pid, SIGCONT)
        setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0)
    }
    print("Resumed \(pids.count) process\(pids.count == 1 ? "" : "es") of \(target.name).")
}

var activeLimiter: Limiter?

@MainActor
func runLimit(_ arguments: [String], watchOnly: Bool) -> Never {
    let (query, options) = splitArguments(arguments)
    var (settings, interval) = parseLimit(options)
    if watchOnly {
        settings.limits = [:]
        settings.efficiencyCoresOnly = false
    }
    let target = resolveTarget(query)
    let limiter = Limiter(target: target, settings: settings)
    activeLimiter = limiter

    let where_ = target.bundlePath ?? "processes named \(target.processName ?? target.name)"
    print("\(watchOnly ? "Watching" : "Limiting") \(target.name) (\(where_)): \(settings.summary). Ctrl-C to stop.")

    for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                activeLimiter?.stop()
                print(isatty(STDOUT_FILENO) == 1 ? "\n" : "", terminator: "")
                print("Stopped. \(target.name) runs freely again.")
                exit(0)
            }
        }
        source.resume()
        signalSources.append(source)
    }

    let interactive = isatty(STDOUT_FILENO) == 1
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(10))
    timer.setEventHandler {
        MainActor.assumeIsolated {
            guard let limiter = activeLimiter else { return }
            let line = describe(limiter.tick(), target: target, settings: settings)
            if interactive {
                let width = Int(terminalWidth())
                print("\r\u{1B}[2K" + String(line.prefix(max(width - 1, 20))), terminator: "")
                fflush(stdout)
            } else {
                print(line)
            }
        }
    }
    timer.resume()
    tickTimer = timer
    while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
}

var signalSources: [DispatchSourceSignal] = []
var tickTimer: DispatchSourceTimer?

func terminalWidth() -> UInt16 {
    var size = winsize()
    return ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? size.ws_col : 120
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "list": runList(Array(arguments.dropFirst()))
case "limit": runLimit(Array(arguments.dropFirst()), watchOnly: false)
case "watch": runLimit(Array(arguments.dropFirst()), watchOnly: true)
case "resume": runResume(Array(arguments.dropFirst()))
case nil, "-h", "--help", "help": print(usage)
case let other?: fail("unknown command \(other). Run apd --help.")
}
