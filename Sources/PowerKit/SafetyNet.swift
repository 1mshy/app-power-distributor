import Darwin
import Foundation

/// Makes sure no app is left frozen (SIGSTOPped) or stuck on the efficiency cores if
/// this process dies without cleaning up — a crash, Force Quit, or `kill -9`.
///
/// Every pid this process might have paused or backgrounded is written to a ledger
/// file. A small guardian process (this same executable, started with
/// `--apd-guardian`) waits for this process to exit, then resumes everything in the
/// ledger. After a clean shutdown the ledger is empty and the guardian just exits.
public enum SafetyNet {
    public static let guardianFlag = "--apd-guardian"

    private static let state = State()

    /// Pids that targets must never include: this process and its guardian.
    public static var protectedPIDs: Set<pid_t> {
        var pids: Set<pid_t> = [getpid()]
        if let guardian = state.guardian { pids.insert(guardian) }
        return pids
    }

    public static var ledgerDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppPowerDistributor/ledgers", isDirectory: true)
    }

    static func newOwnerID() -> Int { state.newOwnerID() }

    static func record(owner: Int, paused: Set<pid_t>) { state.update(owner: owner) { $0.paused = paused } }
    static func record(owner: Int, background: Set<pid_t>) { state.update(owner: owner) { $0.background = background } }
    static func clear(owner: Int) { state.remove(owner: owner) }

    /// Call first thing in `main`. If this process was started as a guardian, it does
    /// the guardian's job and exits; otherwise it returns immediately.
    /// Calling it also tells the safety net that this executable can act as a guardian;
    /// processes that never call it (like test runners) don't get one.
    public static func runGuardianIfRequested(arguments: [String] = CommandLine.arguments) {
        state.canSpawnGuardian = true
        guard arguments.count == 4, arguments[1] == guardianFlag, let parent = pid_t(arguments[2]) else { return }
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        waitForExit(of: parent)
        restore(ledger: URL(fileURLWithPath: arguments[3]))
        exit(0)
    }

    /// Resumes processes listed in ledgers whose owners are gone (in case a guardian
    /// didn't get to run either).
    public static func recoverAbandonedLedgers() {
        let files = (try? FileManager.default.contentsOfDirectory(at: ledgerDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let owner = pid_t(file.deletingPathExtension().lastPathComponent), owner != getpid() else { continue }
            if kill(owner, 0) != 0 && errno == ESRCH { restore(ledger: file) }
        }
    }

    /// Resumes and un-backgrounds everything in a ledger, then deletes it.
    static func restore(ledger: URL) {
        if let data = try? Data(contentsOf: ledger), let entry = try? JSONDecoder().decode(Ledger.self, from: data) {
            for pid in entry.paused { kill(pid, SIGCONT) }
            for pid in entry.background { setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0) }
        }
        try? FileManager.default.removeItem(at: ledger)
    }

    private static func waitForExit(of pid: pid_t) {
        let queue = kqueue()
        guard queue >= 0 else { return }
        defer { close(queue) }
        var change = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: NOTE_EXIT, data: 0, udata: nil
        )
        // Fails with ESRCH if the parent is already gone.
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else { return }
        var event = kevent()
        while kevent(queue, nil, 0, &event, 1, nil) < 0 && errno == EINTR {}
    }

    struct Ledger: Codable {
        var paused: [pid_t] = []
        var background: [pid_t] = []
    }

    struct Entry {
        var paused: Set<pid_t> = []
        var background: Set<pid_t> = []
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var nextOwner = 0
        private var entries: [Int: Entry] = [:]
        private var written = Ledger()
        private var guardianPID: pid_t?
        private var guardianStarted = false
        var canSpawnGuardian = false

        var guardian: pid_t? {
            lock.lock()
            defer { lock.unlock() }
            return guardianPID
        }

        var ledgerURL: URL { SafetyNet.ledgerDirectory.appendingPathComponent("\(getpid()).json") }

        func newOwnerID() -> Int {
            lock.lock()
            defer { lock.unlock() }
            nextOwner += 1
            return nextOwner
        }

        func update(owner: Int, _ change: (inout Entry) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            change(&entries[owner, default: Entry()])
            flush()
        }

        func remove(owner: Int) {
            lock.lock()
            defer { lock.unlock() }
            entries[owner] = nil
            flush()
        }

        // Called with the lock held.
        private func flush() {
            let ledger = Ledger(
                paused: entries.values.reduce(into: Set<pid_t>()) { $0.formUnion($1.paused) }.sorted(),
                background: entries.values.reduce(into: Set<pid_t>()) { $0.formUnion($1.background) }.sorted()
            )
            guard ledger.paused != written.paused || ledger.background != written.background else { return }
            written = ledger
            if ledger.paused.isEmpty && ledger.background.isEmpty {
                try? FileManager.default.removeItem(at: ledgerURL)
                return
            }
            try? FileManager.default.createDirectory(at: SafetyNet.ledgerDirectory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(ledger) {
                try? data.write(to: ledgerURL, options: .atomic)
            }
            startGuardianIfNeeded()
        }

        // Called with the lock held.
        private func startGuardianIfNeeded() {
            guard canSpawnGuardian, !guardianStarted, let executable = Bundle.main.executablePath else { return }
            guardianStarted = true
            let arguments = [executable, SafetyNet.guardianFlag, String(getpid()), ledgerURL.path]
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // Own session, so a Ctrl-C aimed at this process doesn't also kill the guardian.
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
            var argv = arguments.map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            var pid: pid_t = 0
            if posix_spawn(&pid, executable, nil, &attributes, &argv, environ) == 0 {
                guardianPID = pid
            }
        }
    }
}
