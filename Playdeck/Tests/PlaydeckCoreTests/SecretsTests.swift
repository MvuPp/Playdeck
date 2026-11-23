import Foundation
import Testing
@testable import PlaydeckCore

private let tools = AnsibleLocator.locate(savedPath: nil)
private let vaultPassword = #"v@ult p"ss $HOME `x`"#
private let becomePassword = "sudo-Secr3t"

/// In-memory stand-in for the Keychain (swift test never touches the real one).
private final class MemoryStore: PasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    func password(for account: String) -> String? { lock.withLock { items[account] } }
    func hasPassword(for account: String) -> Bool { password(for: account) != nil }
    func setPassword(_ password: String?, for account: String) throws {
        lock.withLock { items[account] = password?.isEmpty == false ? password : nil }
    }
}

private func permissions(_ url: URL) throws -> Int {
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
}

/// Temp project with `group_vars/all/vault.yml` encrypted by ansible-vault (password `vaultPassword`) and a playbook
/// that prints the decrypted value on a local host.
private func vaultProject() async throws -> AnsibleProject {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SecretsTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("group_vars/all"), withIntermediateDirectories: true)
    try "alpha ansible_connection=local ansible_python_interpreter=auto_silent\n"
        .write(to: dir.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
    try "- hosts: all\n  gather_facts: false\n  tasks:\n    - ansible.builtin.debug:\n        msg: \"VAULT={{ vault_value }}\"\n"
        .write(to: dir.appendingPathComponent("site.yml"), atomically: true, encoding: .utf8)
    let vars = dir.appendingPathComponent("group_vars/all/vault.yml")
    try "vault_value: decrypted-ok\n".write(to: vars, atomically: true, encoding: .utf8)
    let scripts = try SecretScripts(DeploySecrets(vaultPassword: vaultPassword))
    defer { scripts.remove() }
    let cmd = try CommandRunner.start(tools!.directory.appendingPathComponent("ansible-vault"),
                                      arguments: ["encrypt"] + scripts.arguments + [vars.path], environment: scripts.environment)
    for await _ in cmd.lines {}
    #expect(await cmd.exitCode() == 0)
    #expect(try String(contentsOf: vars, encoding: .utf8).hasPrefix("$ANSIBLE_VAULT;"))
    return try AnsibleProject(url: dir)
}

/// `playdeck-secrets-*` dirs currently in the temp dir (the suite is serialized, so counts are not disturbed).
private func secretDirs() -> Set<String> {
    Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        .filter { $0.hasPrefix("playdeck-secrets-") })
}

@Suite(.serialized) struct SecretsTests {
    @Test func scriptsHoldNoSecretAndArePrivate() throws {
        let scripts = try SecretScripts(DeploySecrets(vaultPassword: vaultPassword, becomePassword: becomePassword))
        #expect(try permissions(scripts.directory) == 0o700)
        #expect(scripts.arguments.count == 4)
        #expect(scripts.arguments[0] == "--vault-password-file" && scripts.arguments[2] == "--become-password-file")
        for path in [scripts.arguments[1], scripts.arguments[3]] {
            let url = URL(fileURLWithPath: path)
            #expect(url.deletingLastPathComponent().path == scripts.directory.path)
            #expect(try permissions(url) == 0o700)
            let body = try String(contentsOf: url, encoding: .utf8)
            #expect(!body.contains(vaultPassword) && !body.contains(becomePassword))
        }
        #expect(scripts.environment == [SecretScripts.vaultVariable: vaultPassword, SecretScripts.becomeVariable: becomePassword])
        scripts.remove()
        #expect(!FileManager.default.fileExists(atPath: scripts.directory.path))
    }

    @Test func onlyGivenSecretsGetAFile() throws {
        let scripts = try SecretScripts(DeploySecrets(vaultPassword: "", becomePassword: becomePassword))
        defer { scripts.remove() }
        #expect(scripts.arguments.first == "--become-password-file" && scripts.arguments.count == 2)
        #expect(scripts.environment.keys.sorted() == [SecretScripts.becomeVariable])
        #expect(DeploySecrets(vaultPassword: "", becomePassword: nil).isEmpty)
        #expect(!DeploySecrets(becomePassword: "x").isEmpty)
    }

    @Test func secretsComeFromTheStore() throws {
        let store = MemoryStore()
        try store.setPassword("pw", for: "/p1")
        #expect(DeploySecrets(project: "/p1", store: store, becomePassword: "b") == DeploySecrets(vaultPassword: "pw", becomePassword: "b"))
        #expect(DeploySecrets(project: "/p2", store: store).isEmpty)
        try store.setPassword(nil, for: "/p1")
        #expect(!store.hasPassword(for: "/p1"))
    }

    /// The script really feeds ansible-playbook: a vault-encrypted var is decrypted, the become script is accepted
    /// (the play has no `become`, so sudo never runs), the scripts are gone at the end, and neither password shows up
    /// in the log, the command arguments or the saved Run.
    @Test(.enabled(if: tools != nil, "Ansible not installed"))
    func vaultAndBecomeReachAnsibleWithoutLeaking() async throws {
        let p = try await vaultProject()
        defer { try? FileManager.default.removeItem(at: p.url) }
        let pb = p.url.appendingPathComponent("site.yml")
        let secrets = DeploySecrets(vaultPassword: vaultPassword, becomePassword: becomePassword)
        // -vvvv: Ansible's most verbose output (command lines, env handling) must still not show the passwords.
        var verbose = DeployOptions()
        verbose.verbosity = 4

        let run = try DeployService.start(tools: tools!, project: p, playbook: pb, hosts: ["alpha"], check: false,
                                          options: verbose, secrets: secrets)
        let dir = try #require(run.secretsDirectory)
        let result = await run.result()
        #expect(result.exitCode == 0)
        #expect(result.log.contains { $0.contains("VAULT=decrypted-ok") })
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        // Without the password, the same playbook fails: the vault is really in use.
        let without = await (try DeployService.start(tools: tools!, project: p, playbook: pb, hosts: ["alpha"], check: false)).result()
        #expect(without.exitCode != 0)

        let storeDir = FileManager.default.temporaryDirectory.appendingPathComponent("SecretsRuns-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let batch = BatchDeployService.start(tools: tools!, project: p, playbooks: [pb], hosts: ["alpha"], targets: nil, check: false,
                                             store: RunStore(directory: storeDir), secrets: secrets)
        let runs = await batch.result()
        #expect(runs.count == 1 && runs[0].exitCode == 0)
        #expect(runs[0].log.contains { $0.contains("VAULT=decrypted-ok") })
        let saved = try FileManager.default.contentsOfDirectory(at: storeDir, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(!saved.isEmpty)
        for text in [result.log.joined(separator: "\n"), saved, DeployService.arguments(project: p, playbook: pb, hosts: ["alpha"], check: false).joined()] {
            #expect(!text.contains(vaultPassword) && !text.contains(becomePassword))
        }
        // Nothing in the project (.playdeck/ included) holds a password.
        let files = FileManager.default.enumerator(at: p.url, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        #expect(files.contains { $0.path.contains("/.playdeck/") })
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            #expect(!text.contains(vaultPassword) && !text.contains(becomePassword), "\(file.path)")
        }
    }

    /// ansible-playbook cannot be launched: the password scripts are removed anyway.
    @Test func scriptsRemovedWhenLaunchFails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SecretsLaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "alpha\n".write(to: dir.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
        try "- hosts: all\n".write(to: dir.appendingPathComponent("site.yml"), atomically: true, encoding: .utf8)
        let p = try AnsibleProject(url: dir)
        let before = secretDirs()
        #expect(throws: (any Error).self) {
            try DeployService.start(tools: AnsibleTools(directory: URL(fileURLWithPath: "/nonexistent-\(UUID())")), project: p,
                                    playbook: dir.appendingPathComponent("site.yml"), hosts: ["alpha"], check: true,
                                    secrets: DeploySecrets(vaultPassword: vaultPassword))
        }
        #expect(secretDirs() == before)
    }

    /// A cancelled run removes its password scripts too.
    @Test(.enabled(if: tools != nil, "Ansible not installed"))
    func scriptsRemovedWhenCancelled() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SecretsCancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "alpha ansible_connection=local ansible_python_interpreter=auto_silent\n"
            .write(to: dir.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
        try "- hosts: all\n  gather_facts: false\n  tasks:\n    - ansible.builtin.pause: seconds=60\n"
            .write(to: dir.appendingPathComponent("slow.yml"), atomically: true, encoding: .utf8)
        let p = try AnsibleProject(url: dir)
        let run = try DeployService.start(tools: tools!, project: p, playbook: dir.appendingPathComponent("slow.yml"), hosts: ["alpha"],
                                          check: false, secrets: DeploySecrets(becomePassword: becomePassword))
        let scripts = try #require(run.secretsDirectory)
        #expect(FileManager.default.fileExists(atPath: scripts.path))
        for await line in run.lines where line.hasPrefix("TASK [") { break }
        run.cancel()
        let result = await run.result()
        #expect(result.cancelled)
        #expect(!FileManager.default.fileExists(atPath: scripts.path))
    }
}
