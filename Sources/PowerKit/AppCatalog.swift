import AppKit
import Foundation

/// An app bundle, running or installed.
public struct AppInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var bundleID: String?
    public var bundlePath: String
    /// The main process, when running.
    public var pid: pid_t?

    public var id: String { bundlePath }
    public var target: AppTarget { AppTarget(name: name, bundleID: bundleID, bundlePath: bundlePath) }
}

public enum AppLookupError: Error, CustomStringConvertible {
    case notFound(String)
    case ambiguous(String, [String])

    public var description: String {
        switch self {
        case .notFound(let query):
            "No app or running process matches “\(query)”."
        case .ambiguous(let query, let names):
            "“\(query)” matches several apps: \(names.joined(separator: ", ")). Be more specific."
        }
    }
}

public enum AppCatalog {
    /// Apps with a bundle that are running now, excluding this one.
    @MainActor
    public static func runningApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != getpid(), app.activationPolicy != .prohibited,
                  let url = app.bundleURL, url.pathExtension == "app"
            else { return nil }
            return AppInfo(
                name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                bundleID: app.bundleIdentifier,
                bundlePath: url.path,
                pid: app.processIdentifier
            )
        }
    }

    /// Apps in /Applications (one folder deep) and ~/Applications.
    public static func installedApps() -> [AppInfo] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var bundles: [URL] = []
        for root in roots {
            let items = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for item in items {
                if item.pathExtension == "app" {
                    bundles.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let nested = (try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                    bundles += nested.filter { $0.pathExtension == "app" }
                }
            }
        }
        return bundles.map { url in
            AppInfo(
                name: url.deletingPathExtension().lastPathComponent,
                bundleID: Bundle(url: url)?.bundleIdentifier,
                bundlePath: url.path,
                pid: nil
            )
        }
    }

    /// The candidates that best match `query` (by name or bundle id): exact matches if
    /// any, else name prefixes, else substrings.
    public static func bestMatches(for query: String, in apps: [AppInfo]) -> (matches: [AppInfo], exact: Bool) {
        var needle = query.lowercased()
        if needle.hasSuffix(".app") { needle.removeLast(4) }
        func score(_ app: AppInfo) -> Int {
            let name = app.name.lowercased()
            let bundleID = app.bundleID?.lowercased() ?? ""
            if name == needle || bundleID == needle { return 3 }
            if name.hasPrefix(needle) { return 2 }
            if name.contains(needle) || bundleID.contains(needle) { return 1 }
            return 0
        }
        let scored = apps.map { ($0, score($0)) }
        guard let top = scored.map(\.1).max(), top > 0 else { return ([], false) }
        return (scored.filter { $0.1 == top }.map(\.0), top == 3)
    }

    /// Turns what a user typed into a target: an app (running or installed), an .app
    /// path, or else the name of a running process.
    @MainActor
    public static func target(for query: String) throws -> AppTarget {
        if query.hasSuffix(".app"), FileManager.default.fileExists(atPath: query) {
            let url = URL(fileURLWithPath: query).standardizedFileURL
            return AppTarget(name: url.deletingPathExtension().lastPathComponent,
                             bundleID: Bundle(url: url)?.bundleIdentifier, bundlePath: url.path)
        }

        var seen = Set<String>()
        let apps = (runningApps() + installedApps()).filter { seen.insert($0.bundlePath).inserted }
        let (matches, exact) = bestMatches(for: query, in: apps)

        let processExists = ProcessTable.snapshot().entries.values.contains {
            AppTarget.process(named: query).matches($0)
        }
        if processExists && !exact { return .process(named: query) }

        switch matches.count {
        case 1: return matches[0].target
        case 0: throw AppLookupError.notFound(query)
        default:
            // Several bundles of the same app (e.g. a copy in Downloads): prefer the running one.
            let running = matches.filter { $0.pid != nil }
            if running.count == 1 { return running[0].target }
            throw AppLookupError.ambiguous(query, matches.map(\.name).sorted())
        }
    }
}

public enum Format {
    public static func watts(_ value: Double) -> String {
        if value >= 99.5 { return String(format: "%.0f W", value) }
        if value >= 9.95 { return String(format: "%.1f W", value) }
        return String(format: "%.2f W", value)
    }

    public static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    public static func seconds(_ value: Double) -> String {
        value >= 1 ? String(format: "%g s", value) : String(format: "%.0f ms", value * 1000)
    }
}
