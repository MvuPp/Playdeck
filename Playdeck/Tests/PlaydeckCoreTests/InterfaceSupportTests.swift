import Foundation
import Testing
@testable import PlaydeckCore

/// Core helpers used by the O2 interface (no Ansible needed).
@Suite struct InterfaceSupportTests {
    @Test func planIntersectsSelectionWithTargets() {
        let targets: [String: Set<String>] = ["a.yml": ["h1", "h2"], "b.yml": ["h3"], "c.yml": ["h1", "h3"]]
        let steps = BatchDeployService.plan(playbooks: ["a.yml", "b.yml", "c.yml"], hosts: ["h1", "h2"], targets: targets)
        #expect(steps.map(\.hosts) == [["h1", "h2"], [], ["h1"]])
        let pairs = steps.reduce(0) { $0 + $1.hosts.count }
        #expect(pairs == 3)
        #expect(BatchDeployService.plan(playbooks: ["x.yml"], hosts: ["h1"], targets: nil).map(\.hosts) == [["h1"]])
        #expect(BatchDeployService.plan(playbooks: ["unknown.yml"], hosts: ["h1"], targets: targets).map(\.hosts) == [[]])
    }

    @Test func perHostAggregatesCheckedPlaybooksOnly() {
        let matrix: [String: [String: HostDeployStatus]] = [
            "h1": ["a": HostDeployStatus(.upToDate), "b": HostDeployStatus(.neverDeployed)],
            "h2": ["b": HostDeployStatus(.neverDeployed)],
        ]
        let all = StatusService.perHost(matrix, playbooks: ["a", "b"])
        #expect(all["h1"]?.state == .neverDeployed)
        #expect(all["h2"] == HostDeployStatus(.neverDeployed))
        let onlyA = StatusService.perHost(matrix, playbooks: ["a"])
        #expect(onlyA["h1"]?.state == .upToDate)
        #expect(onlyA["h2"] == nil)  // not targeted by a checked playbook
    }

    @Test func countsAndSum() {
        let c = StatusCounts([HostDeployStatus(.upToDate), HostDeployStatus(.outdated(version: "v1", date: Date())),
                              HostDeployStatus(.neverDeployed)])
        let values: [Int] = [c.upToDate, c.outdated, c.neverDeployed, c.total, c.behind]
        #expect(values == [1, 1, 1, 3, 2])
        let sum = c + StatusCounts([HostDeployStatus(.upToDate)])
        #expect(sum.upToDate == 2 && sum.total == 4)
    }

    @Test func batchesGroupRunsByBatchID() {
        func run(_ t: Double, _ batch: UUID?) -> Run {
            Run(date: Date(timeIntervalSince1970: t), projectPath: "/p", playbook: "x.yml", version: "v", hosts: [],
                checkMode: true, exitCode: 0, cancelled: false, results: [], log: [], batchID: batch)
        }
        let (b1, b2) = (UUID(), UUID())
        let runs = [run(6, b2), run(5, b2), run(4, nil), run(3, b1), run(2, nil), run(1, b1)]
        let dates: [[Double]] = RunStore.batches(runs).map { $0.map(\.date.timeIntervalSince1970) }
        #expect(dates == [[6, 5], [4], [3, 1], [2]])
    }

    @Test func projectsByFolderDedupes() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ByFolder-\(UUID().uuidString)")
        for name in ["p1", "p2"] {
            let dir = parent.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "h\n".write(to: dir.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
            try "- hosts: all\n".write(to: dir.appendingPathComponent("site.yml"), atomically: true, encoding: .utf8)
        }
        withDefaults { defaults in
            let lib = ProjectLibrary(defaults: defaults)
            lib.add(parent.appendingPathComponent("p2"))
            lib.add(parent)
            let groups = lib.projectsByFolder()
            #expect(groups.map { $0.projects.map(\.name) } == [["p2"], ["p1"]])
            #expect(lib.projects().map(\.name) == ["p2", "p1"])
        }
    }

    @Test func gitDetection() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NoGit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "h\n".write(to: dir.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
        try "- hosts: all\n".write(to: dir.appendingPathComponent("site.yml"), atomically: true, encoding: .utf8)
        let project = try AnsibleProject(url: dir)
        #expect(await project.gitCommit() == nil)
        _ = try await CommandRunner.run(URL(fileURLWithPath: "/usr/bin/git"), arguments: ["init", "-q"], workingDirectory: dir)
        #expect(await project.gitCommit() == nil)  // no commit yet
    }
}
