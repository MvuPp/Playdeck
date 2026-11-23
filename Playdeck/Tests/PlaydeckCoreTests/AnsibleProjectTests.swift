import Foundation
import Testing
@testable import PlaydeckCore

/// Self-contained project shaped like a real one (ansible.cfg → inventory/hosts.yml, playbook/ with 3 playbooks, roles/,
/// logs/): the tests do not depend on any folder outside the package.
private func sampleProject() throws -> URL {
    let dir = tempDir().appendingPathComponent("debian")
    let files = [
        "ansible.cfg": "[defaults]\ninventory = ./inventory/hosts.yml\nroles_path = ./roles\nlog_path = ./logs/ansible.log\n",
        "inventory/hosts.yml": "---\nall:\n  children:\n    webservers:\n      hosts:\n        serveur:\n",
        "playbook/audit.yml": "- hosts: webservers\n  tasks: []\n",
        "playbook/connect.yml": "- hosts: webservers\n  tasks: []\n",
        "playbook/hardening.yml": "- name: Hardening\n  hosts: webservers\n  roles:\n    - secu\n",
        "roles/secu/tasks/main.yml": "- ansible.builtin.debug:\n    msg: hi\n",
        "logs/.keep": "",
    ]
    for (path, content) in files {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    return dir
}

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AnsibleProjectTests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct AnsibleProjectTests {
    @Test func validProject() throws {
        let project = try AnsibleProject(url: try sampleProject())
        #expect(project.relativePath(project.inventory) == "inventory/hosts.yml")
        #expect(project.playbooks.map(project.relativePath) == ["playbook/audit.yml", "playbook/connect.yml", "playbook/hardening.yml"])
    }

    @Test func emptyFolder() {
        #expect(throws: ProjectError.missing([.inventory, .playbook])) { try AnsibleProject(url: tempDir()) }
    }

    @Test func notADirectory() {
        #expect(throws: ProjectError.notADirectory("/nonexistent")) { try AnsibleProject(url: URL(fileURLWithPath: "/nonexistent")) }
    }

    @Test func folderWithoutPlaybook() throws {
        let dir = try sampleProject()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("playbook"))
        // a YAML file without top-level `hosts:` is not a playbook
        try "- name: x\n  debug: msg=hi\n".write(to: dir.appendingPathComponent("tasks.yml"), atomically: true, encoding: .utf8)
        #expect(throws: ProjectError.missing([.playbook])) { try AnsibleProject(url: dir) }
    }

    @Test func inventoryFallbackWithoutCfg() throws {
        let dir = tempDir()
        try "[web]\nh1\n".write(to: dir.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
        try "- hosts: all\n  tasks: []\n".write(to: dir.appendingPathComponent("site.yaml"), atomically: true, encoding: .utf8)
        let project = try AnsibleProject(url: dir)
        #expect(project.inventory.lastPathComponent == "hosts")
        #expect(project.playbooks.map(\.lastPathComponent) == ["site.yaml"])
    }

    @Test func playbookDetection() {
        #expect(AnsibleProject.isPlaybook("---\n- name: a\n  become: true\n  hosts: web\n"))
        #expect(AnsibleProject.isPlaybook("- hosts: all\n"))
        #expect(!AnsibleProject.isPlaybook("- name: a\n  vars:\n    hosts: x\n"))
        #expect(!AnsibleProject.isPlaybook("all:\n  hosts:\n    a:\n"))
    }

    @Test func parseInventoryIgnoresAllAndUngrouped() throws {
        let json = #"""
        {"_meta":{"hostvars":{"a":{},"b":{},"c":{}}},
         "all":{"children":["ungrouped","web","db"]},
         "ungrouped":{"hosts":["c"]},"web":{"hosts":["a","b"]},"db":{"hosts":["a"]}}
        """#
        let hosts = try AnsibleProject.parseInventory(Data(json.utf8))
        #expect(hosts == [Host(name: "a", groups: ["db", "web"]), Host(name: "b", groups: ["web"]), Host(name: "c", groups: [])])
    }

    @Test func versionOutsideGitIsStable() async throws {
        let dir = try sampleProject()
        let project = try AnsibleProject(url: dir)
        let v1 = project.contentHash()
        #expect(v1.count == 12)
        #expect(project.contentHash() == v1)
        // logs/ and *.retry are excluded; a real file change is not
        try "x".write(to: dir.appendingPathComponent("logs/new.log"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("site.retry"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        #expect(project.contentHash() == v1)
        try "x".write(to: dir.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        #expect(project.contentHash() != v1)
    }

    @Test func versionInGit() async throws {
        let dir = tempDir()
        try "- hosts: all\n".write(to: dir.appendingPathComponent("site.yml"), atomically: true, encoding: .utf8)
        try "h1\n".write(to: dir.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
        let git = URL(fileURLWithPath: "/usr/bin/git")
        for args in [["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]] {
            #expect(try await CommandRunner.run(git, arguments: args, workingDirectory: dir).code == 0)
        }
        let project = try AnsibleProject(url: dir)
        let clean = try #require(await project.gitCommit())
        #expect(!clean.hasSuffix("-dirty"))
        let hash = project.contentHash()
        // An uncommitted edit changes the deploy hash, not just a « -dirty » flag.
        try "h2\n".write(to: dir.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
        #expect(await project.gitCommit() == clean + "-dirty")
        #expect(project.contentHash() != hash)
        let firstEdit = project.contentHash()
        try "h3\n".write(to: dir.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
        #expect(project.contentHash() != firstEdit)
    }

    /// Phase 1 "done" criterion: a debian-like project shows hosts, groups, 3 playbooks and a version.
    @Test(.enabled(if: AnsibleLocator.locate(savedPath: nil) != nil, "Ansible not installed"))
    func debianLoadsEverything() async throws {
        let tools = try #require(AnsibleLocator.locate(savedPath: nil))
        let project = try AnsibleProject(url: try sampleProject())
        let hosts = try await project.loadHosts(tools: tools)
        #expect(hosts == [Host(name: "serveur", groups: ["webservers"])])
        #expect(project.playbooks.count == 3)
        #expect(!(project.contentHash()).isEmpty)
    }
}
