import Foundation

/// A host that reported `changed > 0` on every successful real run of a playbook at one hash (≥ 2 runs).
public struct NonIdempotentHost: Sendable, Hashable {
    public let projectPath: String
    public let playbook: String
    public let host: String
    /// Project hash (`Run.version`) of those runs.
    public let version: String
    /// Number of successful real runs, all with changes.
    public let runs: Int
}

public struct ReliabilityStats: Sendable, Equatable {
    /// Share (0…1) of real deployments with exit code 0 over the last 7 / 30 days; nil = no real deployment then.
    public let successRate7d: Double?
    public let successRate30d: Double?
    /// Date of the latest failed real deployment (exit code ≠ 0).
    public let lastFailure: Date?
    /// Every run, simulations and cancelled runs included.
    public let launches: Int
    /// Mean of `endDate - date` over non-cancelled runs that have an `endDate` (simulations included); nil if none.
    public let averageDuration: TimeInterval?
    public let nonIdempotent: [NonIdempotentHost]
}

/// Real deployments of one calendar day (for the dashboard chart).
public struct DayCount: Sendable, Equatable, Identifiable {
    public let day: Date  // start of the day
    public let successes: Int
    public let failures: Int
    public var id: Date { day }
}

/// Pure statistics on `[Run]` (filter by project / playbook first). « Real deployment » = not `checkMode`, not cancelled.
public enum Reliability {
    public static func stats(_ runs: [Run], now: Date = Date()) -> ReliabilityStats {
        let durations = runs.filter { !$0.cancelled }.compactMap { r in r.endDate.map { $0.timeIntervalSince(r.date) } }
        return ReliabilityStats(
            successRate7d: successRate(runs, since: now.addingTimeInterval(-7 * 86_400)),
            successRate30d: successRate(runs, since: now.addingTimeInterval(-30 * 86_400)),
            lastFailure: runs.filter { isReal($0) && $0.exitCode != 0 }.map(\.date).max(),
            launches: runs.count,
            averageDuration: durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count),
            nonIdempotent: nonIdempotent(runs))
    }

    /// Successful share of real deployments dated `since` or later; nil if there is none.
    public static func successRate(_ runs: [Run], since: Date) -> Double? {
        let real = runs.filter { isReal($0) && $0.date >= since }
        return real.isEmpty ? nil : Double(real.filter { $0.exitCode == 0 }.count) / Double(real.count)
    }

    /// Per (project, playbook, hash): hosts successful in ≥ 2 real runs and `changed > 0` in every one of them.
    /// Sorted by project, playbook, host.
    public static func nonIdempotent(_ runs: [Run]) -> [NonIdempotentHost] {
        struct Key: Hashable { let project, playbook, version, host: String }
        var changes: [Key: [Bool]] = [:]
        for run in runs where isReal(run) {
            for r in run.results where r.status == .success {
                changes[Key(project: run.projectPath, playbook: run.playbook, version: run.version, host: r.host), default: []].append(r.changed > 0)
            }
        }
        return changes.filter { $0.value.count >= 2 && !$0.value.contains(false) }
            .map { NonIdempotentHost(projectPath: $0.key.project, playbook: $0.key.playbook, host: $0.key.host,
                                     version: $0.key.version, runs: $0.value.count) }
            .sorted { ($0.projectPath, $0.playbook, $0.host, $0.version) < ($1.projectPath, $1.playbook, $1.host, $1.version) }
    }

    /// One entry per day over the last `days` days (oldest first, today included, empty days at 0): real deployments only.
    public static func daily(_ runs: [Run], days: Int = 30, now: Date = Date(), calendar: Calendar = .current) -> [DayCount] {
        let today = calendar.startOfDay(for: now)
        var counts: [Date: (ok: Int, ko: Int)] = [:]
        for run in runs where isReal(run) {
            let d = calendar.startOfDay(for: run.date)
            if run.exitCode == 0 { counts[d, default: (0, 0)].ok += 1 } else { counts[d, default: (0, 0)].ko += 1 }
        }
        return (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
            .map { DayCount(day: $0, successes: counts[$0]?.ok ?? 0, failures: counts[$0]?.ko ?? 0) }
    }

    static func isReal(_ run: Run) -> Bool { !run.checkMode && !run.cancelled }
}
