import Foundation
import Testing
@testable import PlaydeckCore

/// Real `ansible-playbook` outputs (ansible-core 2.19, local connection + an unresolvable host).
private func fixture(_ name: String) throws -> [String] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).txt")
    return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
}

@Suite struct RecapParserTests {
    @Test func allOk() throws {
        let r = RecapParser.parse(try fixture("recap_ok"), requested: ["alpha", "beta"])
        #expect(r.map(\.host) == ["alpha", "beta"])
        #expect(r.allSatisfy { $0.status == .success && $0.ok == 1 && $0.failed == 0 })
    }

    @Test func oneFailed() throws {
        let r = RecapParser.parse(try fixture("recap_failed"), requested: ["alpha", "beta"])
        #expect(r.map(\.status) == [.success, .failed])
        #expect(r[0].skipped == 1)
        #expect(r[1].failed == 1 && r[1].ok == 1)
    }

    @Test func unreachable() throws {
        let r = RecapParser.parse(try fixture("recap_unreachable"), requested: ["alpha", "ghost.invalid"])
        #expect(r.map(\.status) == [.success, .unreachable])
        #expect(r[1].unreachable == 1 && r[1].ok == 0)
    }

    @Test func requestedButMissingIsFailed() throws {
        let r = RecapParser.parse(try fixture("recap_ok"), requested: ["alpha", "gamma"])
        #expect(r.map(\.host) == ["alpha", "gamma", "beta"])
        #expect(r[1].status == .failed && r[1].missing)
        #expect(RecapParser.parse(["PLAY [all] ***"], requested: ["x"]).map(\.status) == [.failed])
    }
}

private let tools = AnsibleLocator.locate(savedPath: nil)

/// Temp project: one `ansible_connection=local` host + one unresolvable host, trivial debug + ping playbook (debug alone never connects).
private func localProject() throws -> AnsibleProject {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DeployTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "[local]\nalpha ansible_connection=local ansible_python_interpreter=auto_silent\n[ghost]\nghost.invalid\n"
        .write(to: dir.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
    try "- hosts: all\n  gather_facts: false\n  tasks:\n    - ansible.builtin.debug: msg=hello\n    - ansible.builtin.ping:\n"
        .write(to: dir.appendingPathComponent("site.yml"), atomically: true, encoding: .utf8)
    try "- hosts: all\n  gather_facts: false\n  tasks:\n    - ansible.builtin.pause: seconds=60\n"
        .write(to: dir.appendingPathComponent("slow.yml"), atomically: true, encoding: .utf8)
    return try AnsibleProject(url: dir)
}

@Suite struct DeployServiceTests {
    @Test func argumentsIncludeLimitAndCheck() throws {
        let p = try localProject()
        let pb = p.url.appendingPathComponent("site.yml")
        #expect(DeployService.arguments(project: p, playbook: pb, hosts: ["a", "b"], check: true)
                == ["-i", p.inventory.path, pb.path, "--limit", "a,b", "--check"])
        #expect(DeployService.arguments(project: p, playbook: pb, hosts: ["a"], check: false).last == "a")
    }

    @Test func optionsArguments() throws {
        var o = DeployOptions()
        #expect(o.arguments.isEmpty && o.isDefault)
        o.variables = [.init(key: " env ", value: "prod 1 \"x\"=y"), .init(key: "", value: "ignored"), .init(key: "port", value: "80"),
                       .init(key: "port", value: "8080")]
        o.tags = "web, db "; o.skipTags = "slow"; o.diff = true; o.verbosity = 9
        #expect(o.arguments == ["-e", #"{"env":"prod 1 \"x\"=y","port":"8080"}"#, "--tags", "web, db", "--skip-tags", "slow", "--diff", "-vvvv"])
        let p = try localProject()
        let pb = p.url.appendingPathComponent("site.yml")
        #expect(DeployService.arguments(project: p, playbook: pb, hosts: ["a"], check: true, options: o).suffix(o.arguments.count) == ArraySlice(o.arguments))
    }

    /// The JSON -e really reaches the play, spaces and quotes intact.
    @Test(.enabled(if: AnsibleLocator.locate(savedPath: nil) != nil, "Ansible not installed"))
    func extraVarsReachPlaybook() async throws {
        let p = try localProject()
        try "- hosts: all\n  gather_facts: false\n  tasks:\n    - ansible.builtin.debug:\n        msg: \"VAL={{ greeting }}\"\n"
            .write(to: p.url.appendingPathComponent("vars.yml"), atomically: true, encoding: .utf8)
        var o = DeployOptions()
        o.variables = [.init(key: "greeting", value: #"hello "big" world"#)]
        let run = try DeployService.start(tools: AnsibleLocator.locate(savedPath: nil)!, project: p,
                                          playbook: p.url.appendingPathComponent("vars.yml"), hosts: ["alpha"], check: false, options: o)
        let result = await run.result()
        #expect(result.exitCode == 0)
        #expect(result.log.contains { $0.contains(#"VAL=hello \"big\" world"#) })
    }

    @Test(.enabled(if: tools != nil, "Ansible not installed"))
    func runsTrivialPlaybookLocally() async throws {
        let p = try localProject()
        let run = try DeployService.start(tools: tools!, project: p, playbook: p.url.appendingPathComponent("site.yml"),
                                          hosts: ["alpha", "ghost.invalid"], check: true)
        var streamed = 0
        for await _ in run.lines { streamed += 1 }
        let result = await run.result()
        #expect(streamed == result.log.count && streamed > 0)
        #expect(result.exitCode == 4) // ansible-playbook: 4 = some host unreachable
        #expect(!result.cancelled)
        #expect(result.hosts.map(\.host) == ["alpha", "ghost.invalid"])
        #expect(result.hosts.map(\.status) == [.success, .unreachable])
    }

    @Test(.enabled(if: tools != nil, "Ansible not installed"))
    func cancelEndsStreamQuickly() async throws {
        let p = try localProject()
        let run = try DeployService.start(tools: tools!, project: p, playbook: p.url.appendingPathComponent("slow.yml"),
                                          hosts: ["alpha"], check: false)
        var it = run.lines.makeAsyncIterator()
        while let line = await it.next(), !line.hasPrefix("TASK [") {} // wait until the pause is running
        let start = Date()
        run.cancel()
        while await it.next() != nil {}
        let result = await run.result()
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(result.cancelled)
        #expect(result.hosts.map(\.status) == [.failed])
    }
}

@Suite struct ProcessGroupCancelTests {
    /// A background child keeps the pipe open: only killing the process group ends the stream.
    @Test func cancelKillsChildrenHoldingThePipe() async throws {
        let cmd = try CommandRunner.start(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & echo started; wait"])
        var it = cmd.lines.makeAsyncIterator()
        #expect(await it.next() == "started")
        let start = Date()
        cmd.cancel()
        while await it.next() != nil {}
        _ = await cmd.exitCode()
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
