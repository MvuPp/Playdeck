import Foundation
import Testing
@testable import PlaydeckCore

private let date = Date(timeIntervalSince1970: 1_800_000_000)

/// Temp project with a hosts file and two playbooks (no Ansible needed).
private func project() throws -> AnsibleProject {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Ledger-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("roles/web"), withIntermediateDirectories: true)
    try "a\nb\n".write(to: dir.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
    try "- hosts: all\n".write(to: dir.appendingPathComponent("web.yml"), atomically: true, encoding: .utf8)
    try "- hosts: all\n".write(to: dir.appendingPathComponent("db.yml"), atomically: true, encoding: .utf8)
    try "x: 1\n".write(to: dir.appendingPathComponent("roles/web/main.yml"), atomically: true, encoding: .utf8)
    return try AnsibleProject(url: dir)
}

@Suite struct StatusServiceTests {
    @Test func classifiesThreeStates() {
        #expect(StatusService.classify(nil, version: "v2").state == .neverDeployed)
        #expect(StatusService.classify(LedgerEntry(hash: "v2", date: date), version: "v2").state == .upToDate)
        #expect(StatusService.classify(LedgerEntry(hash: "v1", date: date), version: "v2").state == .outdated(version: "v1", date: date))
        #expect(DeployState.outdated(version: "v1", date: date).isBehind && DeployState.neverDeployed.isBehind)
        #expect(!DeployState.upToDate.isBehind)
    }

    @Test func aggregateIsWorstState() {
        let s = [HostDeployStatus(.upToDate), HostDeployStatus(.outdated(version: "v", date: date)), HostDeployStatus(.upToDate)]
        #expect(StatusService.aggregate(s)?.state == .outdated(version: "v", date: date))
        #expect(StatusService.aggregate(s + [HostDeployStatus(.neverDeployed)])?.state == .neverDeployed)
        #expect(StatusService.aggregate([]) == nil)
    }

    @Test func statusesOnlyForTargetedPlaybooks() {
        let ledger: DeployLedger.Entries = ["a": ["web.yml": LedgerEntry(hash: "v2", date: date)], "b": ["db.yml": LedgerEntry(hash: "v1", date: date)]]
        let s = StatusService.statuses(ledger: ledger, hosts: ["a", "b"], playbooks: ["web.yml", "db.yml"],
                                       targets: ["web.yml": ["a"], "db.yml": ["b"]], version: "v2")
        #expect(s == ["a": ["web.yml": HostDeployStatus(.upToDate)], "b": ["db.yml": HostDeployStatus(.outdated(version: "v1", date: date))]])
    }
}

@Suite struct DeployLedgerTests {
    /// Recording keeps other hosts / playbooks, survives a reload, and does not change the project hash.
    @Test func recordMergesAndIsExcludedFromHash() throws {
        let p = try project()
        let manifest = p.manifest()
        let hash = AnsibleProject.hash(manifest)
        #expect(manifest.keys.sorted() == ["db.yml", "hosts", "roles/web/main.yml", "web.yml"])
        let ledger = DeployLedger(project: p)
        #expect(try ledger.load().isEmpty)
        try ledger.record(hosts: ["a", "b"], playbook: "web.yml", hash: hash, manifest: manifest, date: date)
        try ledger.record(hosts: ["a"], playbook: "db.yml", hash: hash, manifest: manifest, date: date)
        try ledger.record(hosts: ["b"], playbook: "web.yml", hash: "older", manifest: [:], date: date)

        let entries = try DeployLedger(project: p).load()
        #expect(entries["a"] == ["web.yml": LedgerEntry(hash: hash, date: date), "db.yml": LedgerEntry(hash: hash, date: date)])
        #expect(entries["b"]?["web.yml"]?.hash == "older")
        #expect(ledger.manifest(hash) == manifest)
        #expect(FileManager.default.fileExists(atPath: p.url.appendingPathComponent(".playdeck/deployments.json").path))
        #expect(p.contentHash() == hash)  // .playdeck/ is not part of the code
    }

    @Test func changesSinceADeployment() throws {
        let p = try project()
        let old = p.manifest()
        try "x: 2\n".write(to: p.url.appendingPathComponent("roles/web/main.yml"), atomically: true, encoding: .utf8)
        try "- hosts: all\n".write(to: p.url.appendingPathComponent("new.yml"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: p.url.appendingPathComponent("db.yml"))
        let c = FileChanges(from: old, to: p.manifest())
        #expect(c.added == ["new.yml"] && c.modified == ["roles/web/main.yml"] && c.removed == ["db.yml"] && c.count == 3)
        #expect(FileChanges(from: old, to: old).isEmpty)
        #expect(AnsibleProject.hash(old) != p.contentHash())
    }

    /// A merge conflict in deployments.json: an error, not « never deployed », and nothing is overwritten.
    @Test func corruptFileIsReportedNotOverwritten() throws {
        let p = try project()
        let ledger = DeployLedger(project: p)
        try FileManager.default.createDirectory(at: ledger.directory, withIntermediateDirectories: true)
        let file = ledger.directory.appendingPathComponent("deployments.json")
        let conflict = "<<<<<<< HEAD\n{}\n=======\n{}\n>>>>>>> theirs\n"
        try conflict.write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try ledger.load() }
        #expect(throws: (any Error).self) { try ledger.record(hosts: ["a"], playbook: "web.yml", hash: "h", manifest: [:], date: date) }
        #expect(try String(contentsOf: file, encoding: .utf8) == conflict)
    }

    /// 40 records in parallel (as two batches or two app instances would): no host is lost.
    @Test func concurrentRecordsKeepEveryHost() throws {
        let p = try project()
        let ledger = DeployLedger(project: p)
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            try? ledger.record(hosts: ["h\(i)"], playbook: "web.yml", hash: "h", manifest: ["f": "x"], date: date)
        }
        #expect(try ledger.load().count == 40)
        #expect(try String(contentsOf: ledger.directory.appendingPathComponent(".gitignore"), encoding: .utf8) == "deployments.lock\n")
    }
}

@Suite struct ScanTests {
    /// Symlinked file and dir are hashed; `logs` excluded only at the root; ansible.cfg's log_path excluded.
    @Test func symlinksLogsAndLogPath() throws {
        let p = try project()
        let fm = FileManager.default
        let shared = fm.temporaryDirectory.appendingPathComponent("SharedRole-\(UUID().uuidString)")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: shared) }
        try "y: 1\n".write(to: shared.appendingPathComponent("main.yml"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: p.url.appendingPathComponent("roles/shared"), withDestinationURL: shared)
        try fm.createSymbolicLink(at: p.url.appendingPathComponent("link.yml"), withDestinationURL: p.url.appendingPathComponent("web.yml"))
        try fm.createSymbolicLink(at: p.url.appendingPathComponent("roles/web/loop"), withDestinationURL: p.url.appendingPathComponent("roles"))
        try fm.createDirectory(at: p.url.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try "x".write(to: p.url.appendingPathComponent("logs/run.log"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: p.url.appendingPathComponent("roles/web/templates/logs"), withIntermediateDirectories: true)
        try "t".write(to: p.url.appendingPathComponent("roles/web/templates/logs/app.conf.j2"), atomically: true, encoding: .utf8)
        try "[defaults]\nlog_path = ./ansible.log\n".write(to: p.url.appendingPathComponent("ansible.cfg"), atomically: true, encoding: .utf8)
        try "noise".write(to: p.url.appendingPathComponent("ansible.log"), atomically: true, encoding: .utf8)

        let files = p.scan().files
        #expect(files["roles/shared/main.yml"] != nil && files["link.yml"] == files["web.yml"])
        #expect(files["roles/web/templates/logs/app.conf.j2"] != nil)
        #expect(files["logs/run.log"] == nil && files["ansible.log"] == nil && files["ansible.cfg"] != nil)
        #expect(!files.keys.contains { $0.hasPrefix("roles/web/loop/web/loop") })  // the loop is walked once at most

        // Editing the symlinked role changes the hash; writing the log does not.
        let before = p.contentHash()
        try "more noise".write(to: p.url.appendingPathComponent("ansible.log"), atomically: true, encoding: .utf8)
        #expect(p.contentHash() == before)
        try "y: 2\n".write(to: shared.appendingPathComponent("main.yml"), atomically: true, encoding: .utf8)
        #expect(p.contentHash() != before)
    }

    /// Unchanged size + date → the cached hash is reused (the file is not re-read); a change → re-hashed.
    @Test func cacheSkipsUnchangedFiles() throws {
        let p = try project()
        let first = p.scan()
        var cache = first.stamps
        let stamp = try #require(cache["hosts"])
        cache["hosts"] = FileStamp(size: stamp.size, modified: stamp.modified, hash: "from-cache")
        #expect(p.scan(reusing: cache).files["hosts"] == "from-cache")
        try "a\nb\nc\n".write(to: p.url.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
        #expect(p.scan(reusing: cache).files["hosts"] == AnsibleProject.sha256(of: p.url.appendingPathComponent("hosts")))
    }

    @Test(.enabled(if: getuid() != 0, "root reads everything"))
    func unreadableIsReported() throws {
        let p = try project()
        let secret = p.url.appendingPathComponent("roles/web/main.yml")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path) }
        let scan = p.scan()
        #expect(scan.unreadable == ["roles/web/main.yml"] && scan.files["roles/web/main.yml"] == "unreadable")
    }
}
