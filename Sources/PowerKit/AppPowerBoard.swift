import CProbes
import Foundation

/// Measures the power of every running app at once, for "what's using power" lists.
public final class AppPowerBoard {
    private let tracker = EnergyTracker()

    public init() {}

    /// Usage of each app since the previous call (empty on the first call), highest
    /// power first. An app is measured through the coalition it leads, so its helper
    /// processes count toward it.
    public func sample(_ apps: [AppInfo]) -> [(app: AppInfo, usage: Usage)] {
        var coalitionOf: [String: UInt64] = [:]
        for app in apps {
            guard let pid = app.pid else { continue }
            var cid: UInt64 = 0
            guard apd_process_coalition(pid, &cid) == 0, cid != 0,
                  CoalitionLeaders.shared.leader(of: cid) == pid
            else { continue }
            coalitionOf[app.id] = cid
        }
        let rates = tracker.update(Set(coalitionOf.values.map(MeteredEntity.coalition)))
        return apps
            .compactMap { app in
                guard let cid = coalitionOf[app.id], let usage = rates[.coalition(cid)] else { return nil }
                return (app, usage)
            }
            .sorted { $0.usage.watts > $1.usage.watts }
    }
}
