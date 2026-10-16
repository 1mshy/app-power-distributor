import CProbes
import Foundation

/// One live process.
public struct ProcessEntry: Sendable, Hashable {
    public var pid: pid_t
    public var ppid: pid_t
    public var uid: uid_t
    public var name: String
    public var path: String
    public var coalition: UInt64
    public var startMicros: UInt64
    public var isStopped: Bool

    public init(
        pid: pid_t, ppid: pid_t, uid: uid_t = getuid(), name: String, path: String,
        coalition: UInt64, startMicros: UInt64 = 0, isStopped: Bool = false
    ) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.path = path
        self.coalition = coalition
        self.startMicros = startMicros
        self.isStopped = isStopped
    }

    /// Identifies a process across pid reuse.
    public var key: ProcessKey { ProcessKey(pid: pid, startMicros: startMicros) }
}

public struct ProcessKey: Sendable, Hashable {
    public var pid: pid_t
    public var startMicros: UInt64
}

/// A snapshot of the processes this user can control.
public struct ProcessTable: Sendable {
    public var entries: [pid_t: ProcessEntry]

    public init(_ entries: [ProcessEntry]) {
        self.entries = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Reads every process owned by the current user (all processes when running as root).
    public static func snapshot() -> ProcessTable {
        let capacity = 8192
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(apd_list_pids(&pids, Int32(capacity)))
        guard count > 0 else { return ProcessTable([]) }

        let me = geteuid()
        var entries: [ProcessEntry] = []
        entries.reserveCapacity(count)
        var seen = Set<ProcessKey>()
        for pid in pids.prefix(count) where pid > 0 {
            var info = apd_process_info()
            guard apd_process_info_read(pid, &info) == 0 else { continue }
            guard me == 0 || info.uid == me else { continue }
            var cid: UInt64 = 0
            _ = apd_process_coalition(pid, &cid)
            let key = ProcessKey(pid: pid, startMicros: info.start_usec)
            let name = withUnsafeBytes(of: info.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            seen.insert(key)
            entries.append(ProcessEntry(
                pid: pid,
                ppid: info.ppid,
                uid: info.uid,
                name: name,
                path: PathCache.shared.path(for: key, name: name),
                coalition: cid,
                startMicros: info.start_usec,
                isStopped: info.status == UInt32(SSTOP)
            ))
        }
        PathCache.shared.retain(only: seen)
        return ProcessTable(entries)
    }

    public subscript(pid: pid_t) -> ProcessEntry? { entries[pid] }

    /// `roots` plus every process descended from them.
    public func withDescendants(of roots: Set<pid_t>) -> Set<pid_t> {
        var children: [pid_t: [pid_t]] = [:]
        for entry in entries.values { children[entry.ppid, default: []].append(entry.pid) }
        var result = roots
        var queue = Array(roots)
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where result.insert(child).inserted {
                queue.append(child)
            }
        }
        return result
    }
}

/// Executable paths only change on exec (which also changes the name), so look each
/// process up once.
final class PathCache: @unchecked Sendable {
    static let shared = PathCache()
    private let lock = NSLock()
    private var paths: [ProcessKey: (name: String, path: String)] = [:]

    func path(for key: ProcessKey, name: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = paths[key], cached.name == name { return cached.path }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = Int(apd_process_path(key.pid, &buffer, UInt32(buffer.count)))
        let path = length > 0 ? String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        paths[key] = (name, path)
        return path
    }

    func retain(only live: Set<ProcessKey>) {
        lock.lock()
        defer { lock.unlock() }
        paths = paths.filter { live.contains($0.key) }
    }
}
