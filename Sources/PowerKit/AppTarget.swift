import CProbes
import Foundation

/// The app (or command-line program) a limit applies to.
public struct AppTarget: Codable, Hashable, Sendable {
    /// Display name, e.g. "Topaz Video AI".
    public var name: String
    public var bundleID: String?
    /// e.g. "/Applications/Topaz Video AI.app". Every process whose executable lives
    /// inside the bundle belongs to the target.
    public var bundlePath: String?
    /// For targets without a bundle: matches a process's name or executable file name.
    public var processName: String?

    public init(name: String, bundleID: String? = nil, bundlePath: String? = nil, processName: String? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.processName = processName
    }

    public static func process(named name: String) -> AppTarget {
        AppTarget(name: name, processName: name)
    }

    func matches(_ entry: ProcessEntry) -> Bool {
        if let bundlePath, !bundlePath.isEmpty {
            let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
            return entry.path.hasPrefix(prefix)
        }
        if let processName, !processName.isEmpty {
            return entry.name.caseInsensitiveCompare(processName) == .orderedSame
                || (entry.path as NSString).lastPathComponent.caseInsensitiveCompare(processName) == .orderedSame
        }
        return false
    }
}

/// The processes that make up a target right now.
public struct ResolvedTarget: Sendable, Equatable {
    /// Every process to control.
    public var pids: Set<pid_t>
    /// The app's main (window) process, if one stands out.
    public var mainPID: pid_t?
    /// Coalitions the target owns. These are metered as a whole: CPU, GPU and ANE.
    public var coalitions: Set<UInt64>
    /// Processes outside those coalitions (e.g. the app binary started from a shell).
    /// Only their CPU can be metered.
    public var loosePIDs: Set<pid_t>

    public static let empty = ResolvedTarget(pids: [], mainPID: nil, coalitions: [], loosePIDs: [])
    public var isEmpty: Bool { pids.isEmpty }
}

extension AppTarget {
    /// Finds the target's processes.
    ///
    /// A coalition is "owned" when its leader is one of the target's own processes —
    /// true for apps started from Finder or the Dock. An app binary started from a
    /// terminal lands in the terminal's coalition instead; that coalition is not
    /// owned, so the terminal is never throttled along with it.
    public func resolve(
        in table: ProcessTable,
        excluding excluded: Set<pid_t> = SafetyNet.protectedPIDs,
        leaderOf: (UInt64) -> pid_t?
    ) -> ResolvedTarget {
        let roots = Set(table.entries.values.filter(matches).map(\.pid)).subtracting(excluded)
        guard !roots.isEmpty else { return .empty }

        var owned = Set<UInt64>()
        var leaders: [UInt64: pid_t] = [:]
        for cid in Set(roots.compactMap { table[$0]?.coalition }) where cid != 0 {
            if let leader = leaderOf(cid), roots.contains(leader) {
                owned.insert(cid)
                leaders[cid] = leader
            }
        }

        var members = roots
        for entry in table.entries.values where owned.contains(entry.coalition) {
            members.insert(entry.pid)
        }
        members = table.withDescendants(of: members).subtracting(excluded)
        members = members.filter { $0 > 1 }

        let loose = members.filter { pid in !owned.contains(table[pid]?.coalition ?? 0) }
        let main = leaders.values.min()
            ?? roots.min { (table[$0]?.startMicros ?? 0, $0) < (table[$1]?.startMicros ?? 0, $1) }
        return ResolvedTarget(pids: members, mainPID: main, coalitions: owned, loosePIDs: loose)
    }

    public func resolve(in table: ProcessTable, excluding excluded: Set<pid_t> = SafetyNet.protectedPIDs) -> ResolvedTarget {
        resolve(in: table, excluding: excluded, leaderOf: CoalitionLeaders.shared.leader)
    }
}

/// Coalition ids are never reused, so their leaders can be cached.
final class CoalitionLeaders: @unchecked Sendable {
    static let shared = CoalitionLeaders()
    private let lock = NSLock()
    private var leaders: [UInt64: pid_t] = [:]

    func leader(of cid: UInt64) -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        if let leader = leaders[cid] { return leader }
        let leader = apd_coalition_leader(cid)
        guard leader > 0 else { return nil }
        leaders[cid] = leader
        return leader
    }
}
