import Foundation
import Testing
@testable import PlaydeckCore

private let tools = AnsibleLocator.locate(savedPath: nil)

private func tempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Project `<parent>/<name>`: [web] alpha (local) + ghost.invalid (unresolvable), [db] beta (local);
/// web.yml → web, db.yml → db, both.yml → all, slow.yml → a 60 s pause on all.
@discardableResult
private func makeProject(_ parent: URL, _ name: String) throws -> AnsibleProject {
    let dir = parent.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let local = "ansible_connection=local ansible_python_interpreter=auto_silent"
    try "[web]\nalpha \(local)\nghost.invalid\n[db]\nbeta \(local)\n"
        .write(to: dir.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
    for (file, hosts) in [("web.yml", "web"), ("db.yml", "db"), ("both.yml", "all")] {
        try "- hosts: \(hosts)\n  gather_facts: false\n  tasks:\n    - ansible.builtin.ping:\n"
            .write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }
    try "- hosts: all\n  gather_facts: false\n  tasks:\n    - ansible.builtin.pause: seconds=60\n"
        .write(to: dir.appendingPathComponent("slow.yml"), atomically: true, encoding: .utf8)
    return try AnsibleProject(url: dir)
}

/// Dedicated suite, deleted after use: the real UserDefaults are never touched. The suite name is an absolute path in
/// the temp dir (CFPreferences then keeps the plist there): a plain name leaves ~/Library/Preferences/<suite>.plist,
/// which cfprefsd rewrites asynchronously even after the domain is removed and the file deleted.
func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlaydeckTests-\(UUID().uuidString)")
    let name = dir.appendingPathComponent("defaults").path
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: dir)
    }
    try body(defaults)
}

@Suite struct ProjectLibraryTests {
    @Test func scanProjectParentAndInvalid() throws {
        let parent = try tempDir("Library")
        try makeProject(parent, "p2")
        try makeProject(parent, "p1")
        try makeProject(parent, ".hidden")
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("junk"), withIntermediateDirectories: true)

        #expect(ProjectLibrary.scan(parent).map(\.name) == ["p1", "p2"])
        #expect(ProjectLibrary.scan(parent.appendingPathComponent("p1")).map(\.name) == ["p1"])
        #expect(ProjectLibrary.scan(parent.appendingPathComponent("junk")).isEmpty)
        #expect(ProjectLibrary.scan(parent.appendingPathComponent("missing")).isEmpty)
    }

    @Test func persistsDedupesAndRemoves() throws {
        let parent = try tempDir("Library")
        try makeProject(parent, "p1")
        try makeProject(parent, "p2")
        withDefaults { defaults in
            let lib = ProjectLibrary(defaults: defaults)
            lib.add(parent.appendingPathComponent("p2"))
            lib.add(parent)
            lib.add(parent.appendingPathComponent("p2/../p2"))  // same path once standardized
            #expect(ProjectLibrary(defaults: defaults).folders.map(\.path) == [parent.appendingPathComponent("p2").path, parent.path])
            #expect(lib.projects().map(\.name) == ["p2", "p1"])
            lib.remove(parent.appendingPathComponent("p2"))
            #expect(lib.folders.map(\.path) == [parent.path])
            #expect(lib.projects().map(\.name) == ["p1", "p2"])
        }
    }
}

@Suite struct PlaybookTargetsTests {
    /// Real ansible-core 2.19 `--list-hosts` output: 3 plays (web, an empty pattern, all:!beta) + a warning.
    @Test func parsesRealOutput() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/list_hosts.txt")
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        #expect(PlaybookTargets.parse(lines) == ["alpha", "beta", "gamma"])
        #expect(PlaybookTargets.parse(["  play #1 (x): x\tTAGS: []", "    pattern: ['x']", "    hosts (0):", ""]).isEmpty)
    }

    @Test(.enabled(if: tools != nil, "Ansible not installed"))
    func loadsLocally() async throws {
        let p = try makeProject(try tempDir("Targets"), "proj")
        let t = try await PlaybookTargets.load(tools: tools!, project: p)
        #expect(t == ["web.yml": ["alpha", "ghost.invalid"], "db.yml": ["beta"],
                      "both.yml": ["alpha", "beta", "ghost.invalid"], "slow.yml": ["alpha", "beta", "ghost.invalid"]])
    }
}

@Suite struct BatchDeployTests {
    /// Real run: web.yml only on web hosts, db.yml only on beta, both.yml on all; ghost.invalid fails web.yml
    /// but still gets both.yml (independent playbooks); one run per playbook, successes recorded in .playdeck/.
    @Test(.enabled(if: tools != nil, "Ansible not installed"))
    func eachHostGetsItsPlaybooks() async throws {
        let parent = try tempDir("Batch")
        let p = try makeProject(parent, "proj")
        let store = RunStore(directory: parent.appendingPathComponent("runs"))
        let targets = try await PlaybookTargets.load(tools: tools!, project: p)
        let playbooks = ["both.yml", "db.yml", "web.yml"].map { p.url.appendingPathComponent($0) }

        let batch = BatchDeployService.start(tools: tools!, project: p, playbooks: playbooks, hosts: ["alpha", "beta", "ghost.invalid"],
                                             targets: targets, check: false, store: store)
        var started: [String: [String]] = [:]
        for await event in batch.events { if case let .playbookStarted(_, count, pb, hosts) = event { #expect(count == 3); started[pb] = hosts } }
        let runs = await batch.result()

        #expect(started == ["both.yml": ["alpha", "beta", "ghost.invalid"], "db.yml": ["beta"], "web.yml": ["alpha", "ghost.invalid"]])
        #expect(runs.map(\.playbook) == ["both.yml", "db.yml", "web.yml"])
        #expect(runs.allSatisfy { $0.batchID == batch.id && $0.ledgerError == nil && $0.version == p.contentHash() })
        #expect(runs.allSatisfy { r in r.endDate.map { $0 >= r.date } == true })
        #expect(runs[2].results.map(\.status) == [.success, .unreachable])
        #expect(Set(store.load().map(\.id)) == Set(runs.map(\.id)))

        let s = StatusService.statuses(ledger: try DeployLedger(project: p).load(), hosts: ["alpha", "beta", "ghost.invalid"],
                                       playbooks: ["both.yml", "db.yml", "web.yml"], targets: targets, version: p.contentHash())
        #expect(s["alpha"] == ["both.yml": HostDeployStatus(.upToDate), "web.yml": HostDeployStatus(.upToDate)])
        #expect(s["beta"] == ["both.yml": HostDeployStatus(.upToDate), "db.yml": HostDeployStatus(.upToDate)])
        // Unreachable on both playbooks: never recorded.
        #expect(s["ghost.invalid"] == ["both.yml": HostDeployStatus(.neverDeployed), "web.yml": HostDeployStatus(.neverDeployed)])

        // A simulation records nothing.
        try FileManager.default.removeItem(at: p.url.appendingPathComponent(".playdeck"))
        let sim = BatchDeployService.start(tools: tools!, project: p, playbooks: playbooks, hosts: ["alpha"], targets: targets,
                                           check: true, store: store)
        for await _ in sim.events {}
        _ = await sim.result()
        #expect(try DeployLedger(project: p).load().isEmpty)
    }

    /// Unselected targets → skipped; cancelling the first playbook stops the batch.
    @Test(.enabled(if: tools != nil, "Ansible not installed"))
    func skipAndCancel() async throws {
        let parent = try tempDir("BatchCancel")
        let p = try makeProject(parent, "proj")
        let store = RunStore(directory: parent.appendingPathComponent("runs"))
        let playbooks = ["db.yml", "slow.yml", "web.yml"].map { p.url.appendingPathComponent($0) }
        let batch = BatchDeployService.start(tools: tools!, project: p, playbooks: playbooks, hosts: ["alpha"],
                                             targets: ["db.yml": ["beta"], "slow.yml": ["alpha"], "web.yml": ["alpha"]],
                                             check: false, store: store)
        var events: [BatchEvent] = []
        var it = batch.events.makeAsyncIterator()
        while let e = await it.next() {
            events.append(e)
            if case .line(let l) = e, l.hasPrefix("TASK [") { break }  // the pause is running
        }
        let start = Date()
        batch.cancel()
        while let e = await it.next() { events.append(e) }
        let runs = await batch.result()

        #expect(Date().timeIntervalSince(start) < 10)
        #expect(events.first == .playbookSkipped(index: 0, count: 3, playbook: "db.yml"))
        #expect(!events.contains { if case .playbookStarted(2, _, _, _) = $0 { true } else { false } })
        #expect(runs.count == 1 && runs[0].playbook == "slow.yml" && runs[0].cancelled && runs[0].ledgerError == nil)
        #expect(try DeployLedger(project: p).load().isEmpty)  // cancelled: nothing recorded
        #expect(store.load().map(\.id) == [runs[0].id])
    }
}
