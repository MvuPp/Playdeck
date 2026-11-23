import Foundation
import Testing
@testable import PlaydeckCore

/// Real `ansible-lint 26.11.0 -f sarif --nocolor --offline` stdout on the project written by `writeLintProject`
/// (SRCROOT replaced by file:///project/).
private let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ansible_lint_26.11.sarif.json")

private let lintProjectFiles: [String: String] = [
    "ansible.cfg": "[defaults]\ninventory = hosts.ini\nroles_path = ./roles\nlog_path = ./ansible.log\n",  // log_path: must stay unwritten
    "hosts.ini": "[web]\nlocalhost ansible_connection=local\n",
    "site.yml": "- hosts: web\n  tasks:\n    - shell: echo hello\n    - name: install\n      apt: name=nginx state=latest\n",
    "playbooks/broken.yml": "---\n- name: Broken\n  hosts: web\n  tasks:\n    - name: Bad module\n      ansible.builtin.nosuchmodule:\n        x: 1\n",
    "playbooks/clean.yml": "---\n- name: Clean playbook\n  hosts: web\n  tasks:\n    - name: Ping\n      ansible.builtin.ping:\n",
    "playbooks/inc.yml": "---\n- name: Include role\n  hosts: web\n  tasks:\n    - name: Use role\n      ansible.builtin.include_role:\n        name: web\n"
        + "    - name: Ignore\n      ansible.builtin.command: /bin/true\n      ignore_errors: true\n      changed_when: false\n",
    "playbooks/roles.yml": "---\n- name: With role\n  hosts: web\n  roles:\n    - web\n",
    "roles/web/tasks/main.yml": "---\n- command: ls\n- name: copy file\n  copy: src=a dest=/tmp/b\n",
]

private func tempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeProject(_ files: [String: String], in dir: URL) throws -> AnsibleProject {
    for (path, text) in files {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return try AnsibleProject(url: dir)
}

private func fixtureIssues() throws -> [LintIssue] { try Quality.parseSARIF(Data(contentsOf: fixtureURL)) }

private func issue(_ severity: LintSeverity, _ rule: String = "r", file: String = "a.yml") -> LintIssue {
    LintIssue(rule: rule, severity: severity, file: file, line: 1, message: "m")
}

@Suite struct LintParsingTests {
    @Test func parsesRealSARIF() throws {
        let issues = try fixtureIssues()
        #expect(issues.count == 18)
        #expect(Set(issues.map(\.file)) == ["playbooks/broken.yml", "playbooks/inc.yml", "roles/web/tasks/main.yml", "site.yml"])
        let syntax = try #require(issues.first { $0.rule == "syntax-check[unknown-module]" })
        #expect(syntax.file == "playbooks/broken.yml" && syntax.line == 5 && syntax.severity == .high && syntax.isFatal)
        #expect(syntax.message.contains("ansible.builtin.nosuchmodule"))
        let site = issues.filter { $0.file == "site.yml" }
        #expect(site.map { $0.line ?? 0 } == site.map { $0.line ?? 0 }.sorted())
        #expect(site.first { $0.rule == "no-changed-when" }?.severity == .high)
        #expect(site.first { $0.rule == "fqcn[action-core]" }?.severity == .medium)
        #expect(site.first { $0.rule == "package-latest" }?.line == 4)
        #expect(site.first { $0.rule == "name[missing]" }?.helpURL == "https://docs.ansible.com/projects/lint/rules/name/")
        #expect(!issues.contains { $0.file.hasPrefix("/") })
    }

    @Test func nonErrorResultIsLow() throws {
        let json = """
        {"runs":[{"tool":{"driver":{"rules":[{"id":"x","defaultConfiguration":{"level":"error"}},{"id":"n","defaultConfiguration":{"level":"note"}}]}},
        "results":[{"ruleId":"x","level":"warning","message":{"text":"w"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.yml"}}}]},
        {"ruleId":"n","level":"error","message":{"text":"n"},"locations":[]}]}]}
        """
        let issues = try Quality.parseSARIF(Data(json.utf8))
        #expect(issues.map(\.severity) == [.low, .low])
        #expect(issues.first { $0.rule == "x" }?.line == nil)
        #expect(throws: (any Error).self) { try Quality.parseSARIF(Data("not json".utf8)) }
    }
}

@Suite struct GradeTests {
    @Test func thresholds() {
        #expect(Quality.grade([]) == .A)
        #expect(Quality.grade(Array(repeating: issue(.low), count: 4)) == .B)
        #expect(Quality.grade([issue(.high)]) == .C)
        #expect(Quality.grade(Array(repeating: issue(.medium), count: 7)) == .C)  // 14
        #expect(Quality.grade(Array(repeating: issue(.high), count: 3)) == .D)    // 15
        #expect(Quality.grade(Array(repeating: issue(.high), count: 6)) == .E)    // 30
        #expect(Quality.grade(Array(repeating: issue(.high), count: 10)) == .F)   // 50
        #expect(Quality.grade([issue(.low, "syntax-check[specific]")]) == .F)
        #expect(Quality.grade([issue(.low, "load-failure[filenotfounderror]")]) == .F)
        #expect(Grade.A < Grade.F && LintSeverity.low < LintSeverity.high)
    }

    @Test func gradesFromFixture() throws {
        let issues = try fixtureIssues()
        let texts = lintProjectFiles.filter { $0.key.hasSuffix(".yml") && !$0.key.hasPrefix("roles/") }
        let report = LintReport(hash: "h", issues: issues, playbookIssues: Quality.attribute(issues, playbooks: texts))
        #expect(report.grade(forPlaybook: "playbooks/clean.yml") == .A)
        #expect(report.grade(forPlaybook: "site.yml") == .D)              // 24 points
        #expect(report.grade(forPlaybook: "playbooks/broken.yml") == .F)  // syntax-check
        // roles: (role web, 20 points) and include_role web (+ ignore-errors 2 points)
        #expect(report.playbookIssues["playbooks/roles.yml"]?.count == 7)
        #expect(report.playbookIssues["playbooks/roles.yml"]?.allSatisfy { $0.file == "roles/web/tasks/main.yml" } == true)
        #expect(report.playbookIssues["playbooks/inc.yml"]?.count == 8)
        #expect(report.grade(forPlaybook: "playbooks/inc.yml") == .D)
        #expect(report.playbookIssues["site.yml"]?.contains { $0.file.hasPrefix("roles/") } == false)
        #expect(report.projectGrade() == .F)
        #expect(report.byFile["roles/web/tasks/main.yml"]?.count == 7)
        #expect(report.grade(forPlaybook: "unknown.yml") == .A)
        // A failed `ansible-playbook --syntax-check` forces F even when ansible-lint found nothing.
        #expect(report.grade(forPlaybook: "playbooks/clean.yml", syntaxOK: false) == .F)
        let clean = LintReport(hash: "h", issues: [], playbookIssues: ["a.yml": []])
        #expect(clean.projectGrade() == .A && clean.projectGrade(syntaxOK: false) == .F)
    }
}

@Suite struct RoleReferenceTests {
    @Test func rolesList() {
        let yaml = """
        - hosts: all
          roles:
            - common
            - role: web
              tags: [web]
            - { role: geerlingguy.mysql, when: x }
            - name: ns.col.nginx
            - "roles/quoted"
          tasks:
            - name: not a role
              ansible.builtin.debug: msg=hi
        - hosts: db
          roles:
          - flat
        """
        #expect(Quality.referencedRoles(yaml) == ["common", "web", "mysql", "nginx", "quoted", "flat"])
    }

    @Test func includeAndImport() {
        let yaml = """
        - hosts: all
          tasks:
            - name: Use
              ansible.builtin.include_role:
                name: alpha
            - import_role:
                name: beta
            - name: other
              ansible.builtin.debug:
                msg: "{{ x }}"
              vars:
                name: notarole
            - include_role:
                name: "{{ dynamic }}"
        """
        #expect(Quality.referencedRoles(yaml) == ["alpha", "beta"])
    }

    @Test func roleOfFile() {
        #expect(Quality.roleName(ofFile: "roles/web/tasks/main.yml") == "web")
        #expect(Quality.roleName(ofFile: "playbooks/roles/db/handlers/main.yml") == "db")
        #expect(Quality.roleName(ofFile: "site.yml") == nil)
        #expect(Quality.roleName(ofFile: "roles/README.md") == nil)
    }
}

private let tools = AnsibleLocator.locate(savedPath: nil)
private let lint = AnsibleLocator.locateLint()

@Suite struct QualityServiceTests {
    /// A fake ansible-lint that counts its calls and prints `output`: same hash → one run only.
    @Test func lintIsCachedByHash() async throws {
        let dir = try tempDir("LintCache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = try writeProject(lintProjectFiles, in: dir.appendingPathComponent("proj"))
        let counter = dir.appendingPathComponent("count")
        let fake = dir.appendingPathComponent("ansible-lint")
        try "#!/bin/sh\necho x >> '\(counter.path)'\necho noise >&2\ncat '\(fixtureURL.path)'\nexit 2\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let calls = { (try? String(contentsOf: counter, encoding: .utf8))?.split(separator: "\n").count ?? 0 }

        let service = QualityService(tools: AnsibleTools(directory: URL(fileURLWithPath: "/usr/bin")), lint: fake)
        let a = try await service.lint(project, hash: "h1")
        let b = try await service.lint(project, hash: "h1")
        #expect(a == b && a.issues.count == 18 && a.hash == "h1" && calls() == 1)
        #expect(a.playbookIssues.keys.sorted() == ["playbooks/broken.yml", "playbooks/clean.yml", "playbooks/inc.yml", "playbooks/roles.yml", "site.yml"])
        _ = try await service.lint(project, hash: "h2")
        #expect(calls() == 2)
        _ = try await service.lint(project)  // hash from the files
        #expect(calls() == 3)

        try "#!/bin/sh\necho broken config >&2\nexit 3\n".write(to: fake, atomically: true, encoding: .utf8)
        await #expect(throws: QualityError.lintFailed(code: 3, output: "broken config")) { try await service.lint(project, hash: "h3") }
        await #expect(throws: QualityError.lintNotInstalled) {
            try await QualityService(tools: AnsibleTools(directory: URL(fileURLWithPath: "/usr/bin")), lint: nil).lint(project)
        }
    }

    /// Real ansible-lint on the fixture project: same findings as the fixture, project files untouched.
    @Test(.enabled(if: lint != nil && tools != nil, "ansible-lint not installed"))
    func realLintMatchesFixture() async throws {
        let dir = try tempDir("LintReal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = try writeProject(lintProjectFiles, in: dir)
        let before = try FileManager.default.subpathsOfDirectory(atPath: dir.path).sorted()
        let hash = project.contentHash()
        let report = try await QualityService(tools: tools!, lint: lint).lint(project)
        let key = { (i: LintIssue) in "\(i.file):\(i.line ?? 0):\(i.rule):\(i.severity)" }
        #expect(report.issues.map(key) == (try fixtureIssues()).map(key))
        #expect(report.hash == hash && project.contentHash() == hash)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: dir.path).sorted() == before)
    }

    @Test(.enabled(if: tools != nil, "Ansible not installed"))
    func syntaxCheck() async throws {
        let dir = try tempDir("SyntaxCheck")
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = try writeProject([
            "hosts": "localhost ansible_connection=local\n",
            "ansible.cfg": "[defaults]\nlog_path = ./ansible.log\n",
            "ok.yml": "- hosts: all\n  gather_facts: false\n  tasks:\n    - ansible.builtin.debug: msg=hi\n",
            "bad.yml": "- hosts: all\n  tasks:\n    - ansible.builtin.nosuchmodule_xyz:\n        a: 1\n",
        ], in: dir)
        let service = QualityService(tools: tools!, lint: nil)
        let results = await service.syntaxCheck(project)
        #expect(results.map(\.playbook) == ["bad.yml", "ok.yml"])
        #expect(results[1] == SyntaxCheckResult(playbook: "ok.yml", ok: true, message: ""))
        #expect(!results[0].ok && results[0].message.contains("nosuchmodule_xyz"))
        #expect(await service.syntaxCheck(project) == results)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("ansible.log").path))
    }

    /// Homebrew layout: bin/ansible-playbook is a symlink into <prefix>/libexec/bin, collections in libexec/lib/python3.x/site-packages.
    @Test func collectionsOfPlaydecksAnsible() throws {
        let dir = try tempDir("Collections")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let site = dir.appendingPathComponent("libexec/lib/python3.13/site-packages")
        try fm.createDirectory(at: site.appendingPathComponent("ansible_collections"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("libexec/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try "".write(to: dir.appendingPathComponent("libexec/bin/ansible-playbook"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("bin/ansible-playbook").path,
                                  withDestinationPath: dir.appendingPathComponent("libexec/bin/ansible-playbook").path)
        let found = Quality.collectionsDirectory(AnsibleTools(directory: dir.appendingPathComponent("bin")))
        #expect(found.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == site.resolvingSymlinksInPath())
        #expect(Quality.collectionsDirectory(AnsibleTools(directory: dir)) == nil)
    }
}
