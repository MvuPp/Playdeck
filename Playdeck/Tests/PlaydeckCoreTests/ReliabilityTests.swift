import Foundation
import Testing
@testable import PlaydeckCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400

private func run(_ daysAgo: Double, exit: Int32 = 0, check: Bool = false, cancelled: Bool = false, playbook: String = "site.yml",
                 version: String = "v1", changed: [String: Int] = [:], duration: TimeInterval? = nil) -> Run {
    let date = now.addingTimeInterval(-daysAgo * day)
    let results = changed.keys.sorted().map { host -> HostResult in
        var r = HostResult(host: host); r.ok = 2; r.changed = changed[host]!; return r
    }
    return Run(date: date, projectPath: "/p", playbook: playbook, version: version, hosts: changed.keys.sorted(), checkMode: check,
               exitCode: exit, cancelled: cancelled, results: results, log: [], endDate: duration.map { date.addingTimeInterval($0) })
}

@Suite struct ReliabilityTests {
    @Test func dailyCountsRealDeploymentsOnly() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let runs = [run(0), run(0, exit: 2), run(1, check: true), run(1, cancelled: true), run(2), run(40)]
        let d = Reliability.daily(runs, days: 3, now: now, calendar: cal)
        #expect(d.map(\.day) == [2, 1, 0].map { cal.startOfDay(for: now.addingTimeInterval(-Double($0) * day)) })
        #expect(d.map(\.successes) == [1, 0, 1])
        #expect(d.map(\.failures) == [0, 0, 1])
    }

    @Test func ratesExcludeSimulationsAndCancelled() {
        let runs = [run(1), run(2, exit: 2), run(3, exit: 2, check: true), run(4, cancelled: true, duration: 999),
                    run(10, exit: 4, duration: 30), run(40, exit: 2, duration: 10), run(5, check: true, duration: 20)]
        let s = Reliability.stats(runs, now: now)
        #expect(s.successRate7d == 0.5)                  // run(1) ok, run(2) failed
        #expect(s.successRate30d == 1.0 / 3.0)           // + run(10) failed
        #expect(s.lastFailure == now.addingTimeInterval(-2 * day))
        #expect(s.launches == 7)
        #expect(s.averageDuration == 20)                 // 30, 10, 20 (cancelled run ignored)
        #expect(Reliability.stats([run(1, check: true)], now: now).successRate7d == nil)
        #expect(Reliability.stats([], now: now) == ReliabilityStats(successRate7d: nil, successRate30d: nil, lastFailure: nil,
                                                                   launches: 0, averageDuration: nil, nonIdempotent: []))
    }

    @Test func idempotence() {
        var failedHost = run(3, changed: ["c": 1])
        failedHost.results[0].failed = 1                 // c failed once: only one successful run left
        let runs = [
            run(1, changed: ["a": 2, "b": 0, "c": 1]),
            run(2, changed: ["a": 1, "b": 3]),
            failedHost,
            run(4, changed: ["a": 1], duration: 5).with(check: true),     // simulation: ignored
            run(5, playbook: "db.yml", changed: ["a": 1]),                  // only one run of db.yml
            run(6, version: "v0", changed: ["d": 1]), run(7, version: "v2", changed: ["d": 1]),  // different hashes
            run(8, version: "v3", changed: ["e": 1]), run(9, version: "v3", changed: ["e": 1]),
        ]
        #expect(Reliability.nonIdempotent(runs) == [
            NonIdempotentHost(projectPath: "/p", playbook: "site.yml", host: "a", version: "v1", runs: 2),
            NonIdempotentHost(projectPath: "/p", playbook: "site.yml", host: "e", version: "v3", runs: 2),
        ])
        #expect(Reliability.stats(runs, now: now).nonIdempotent.count == 2)
    }

    /// A run file saved before Phase 6 (no `endDate`) still loads.
    @Test func decodesRunWithoutEndDate() throws {
        let json = """
        {"cancelled":false,"checkMode":false,"date":"2026-11-20T10:00:00Z","exitCode":0,"hosts":["a"],
         "id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","log":[],"playbook":"site.yml","projectPath":"/p",
         "results":[{"changed":1,"failed":0,"host":"a","ignored":0,"missing":false,"ok":2,"rescued":0,"skipped":0,"unreachable":0}],
         "version":"abc"}
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OldRun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("old.json"), atomically: true, encoding: .utf8)
        let store = RunStore(directory: dir)
        let loaded = store.load()
        #expect(loaded.count == 1 && loaded[0].endDate == nil && loaded[0].results[0].changed == 1)

        var withEnd = loaded[0]
        withEnd.endDate = withEnd.date.addingTimeInterval(42)
        withEnd.id = UUID()
        try store.save(withEnd)
        #expect(store.load().first { $0.id == withEnd.id }?.endDate == withEnd.endDate)
    }
}

private extension Run {
    func with(check: Bool) -> Run { var r = self; r.checkMode = check; return r }
}
