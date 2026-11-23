import Foundation

/// Deployment state of one host for one (project, playbook), or aggregated over several playbooks.
public enum DeployState: Sendable, Equatable {
    case upToDate
    /// Last deployed at another hash (`date` of that deployment).
    case outdated(version: String, date: Date)
    case neverDeployed

    /// Hosts to pre-select for a redeploy.
    public var isBehind: Bool { self != .upToDate }
}

public struct HostDeployStatus: Sendable, Equatable {
    public var state: DeployState

    public init(_ state: DeployState) { self.state = state }
}

/// Counters for the header tiles and gauges.
public struct StatusCounts: Sendable, Equatable {
    public var upToDate = 0, outdated = 0, neverDeployed = 0

    public init() {}
    public init(_ statuses: some Sequence<HostDeployStatus>) {
        for s in statuses {
            switch s.state {
            case .upToDate: upToDate += 1
            case .outdated: outdated += 1
            case .neverDeployed: neverDeployed += 1
            }
        }
    }

    public var total: Int { upToDate + outdated + neverDeployed }
    /// Hosts to redeploy (`DeployState.isBehind`).
    public var behind: Int { outdated + neverDeployed }

    public static func + (a: Self, b: Self) -> Self {
        var r = a
        r.upToDate += b.upToDate; r.outdated += b.outdated; r.neverDeployed += b.neverDeployed
        return r
    }
}

/// States computed from the project's `.playdeck/` record: instant, offline, no SSH.
public enum StatusService {
    /// Status of one (host, playbook) from its recorded deployment.
    public static func classify(_ entry: LedgerEntry?, version: String) -> HostDeployStatus {
        guard let entry else { return HostDeployStatus(.neverDeployed) }
        return HostDeployStatus(entry.hash == version ? .upToDate : .outdated(version: entry.hash, date: entry.date))
    }

    /// Worst status (never deployed > outdated > up to date). nil if empty.
    public static func aggregate(_ statuses: [HostDeployStatus]) -> HostDeployStatus? {
        func rank(_ s: DeployState) -> Int {
            switch s { case .upToDate: 0; case .outdated: 1; case .neverDeployed: 2 }
        }
        return statuses.max { rank($0.state) < rank($1.state) }
    }

    /// Aggregate (worst) status of each host over the `playbooks` that target it; hosts targeted by none are left out.
    public static func perHost(_ statuses: [String: [String: HostDeployStatus]], playbooks: Set<String>) -> [String: HostDeployStatus] {
        statuses.compactMapValues { aggregate($0.filter { playbooks.contains($0.key) }.map(\.value)) }
    }

    /// Status per host, then per playbook (relative path), only for the playbooks whose `hosts:` targets that host
    /// (`targets` from `PlaybookTargets.load`; nil = every playbook applies to every host).
    public static func statuses(ledger: DeployLedger.Entries, hosts: [String], playbooks: [String],
                                targets: [String: Set<String>]?, version: String) -> [String: [String: HostDeployStatus]] {
        var result: [String: [String: HostDeployStatus]] = [:]
        for playbook in playbooks {
            for host in hosts where targets.map({ $0[playbook]?.contains(host) == true }) ?? true {
                result[host, default: [:]][playbook] = classify(ledger[host]?[playbook], version: version)
            }
        }
        return result
    }
}
