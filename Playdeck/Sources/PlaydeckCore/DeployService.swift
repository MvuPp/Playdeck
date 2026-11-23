import Foundation

public struct DeployResult: Sendable {
    public let exitCode: Int32
    public let cancelled: Bool
    public let hosts: [HostResult]
    public let log: [String]
}

/// A running `ansible-playbook`: live log, cancel, final result.
public final class Deployment: @unchecked Sendable {
    /// Log lines as they arrive (stdout + stderr). Finishes when the run ends.
    public let lines: AsyncStream<String>
    private let command: RunningCommand
    private let task: Task<DeployResult, Never>
    private let cancelFlag = Flag()
    /// Temp dir of the password scripts (nil without secrets); deleted when the process ends.
    public let secretsDirectory: URL?

    init(command: RunningCommand, hosts: [String], scripts: SecretScripts? = nil) {
        self.command = command
        secretsDirectory = scripts?.directory
        let (lines, cont) = AsyncStream<String>.makeStream()
        self.lines = lines
        let flag = cancelFlag
        task = Task {
            defer { scripts?.remove() }
            var log: [String] = []
            for await line in command.lines {
                log.append(line)
                cont.yield(line)
            }
            cont.finish()
            let code = await command.exitCode()
            return DeployResult(exitCode: code, cancelled: flag.value,
                                hosts: RecapParser.parse(log, requested: hosts), log: log)
        }
    }

    /// Stops ansible-playbook and its ssh children (whole process group).
    public func cancel() {
        cancelFlag.value = true
        command.cancel()
    }

    /// Waits for the end of the run (the log is collected even if nobody reads `lines`).
    public func result() async -> DeployResult { await task.value }
}

public enum DeployService {
    public static func arguments(project: AnsibleProject, playbook: URL, hosts: [String], check: Bool,
                                 options: DeployOptions = .init()) -> [String] {
        ["-i", project.inventory.path, playbook.path, "--limit", hosts.joined(separator: ",")] + (check ? ["--check"] : [])
            + options.arguments
    }

    /// Runs `ansible-playbook -i <inv> <playbook> --limit h1,h2 [--check]` from the project dir (so its ansible.cfg applies).
    /// `secrets` go through `SecretScripts` (`--vault-password-file` / `--become-password-file`), removed when the process ends.
    public static func start(tools: AnsibleTools, project: AnsibleProject, playbook: URL,
                             hosts: [String], check: Bool, options: DeployOptions = .init(),
                             secrets: DeploySecrets = .init()) throws -> Deployment {
        precondition(!hosts.isEmpty, "an empty --limit would target every host")
        let scripts = secrets.isEmpty ? nil : try SecretScripts(secrets)
        let cmd: RunningCommand
        do {
            cmd = try CommandRunner.start(tools.playbook,
                                          arguments: arguments(project: project, playbook: playbook, hosts: hosts, check: check, options: options)
                                              + (scripts?.arguments ?? []),
                                          workingDirectory: project.url, environment: scripts?.environment ?? [:])
        } catch {
            scripts?.remove()
            throw error
        }
        return Deployment(command: cmd, hosts: hosts, scripts: scripts)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Which hosts each playbook's own `hosts:` targets (`ansible-playbook --list-hosts`, inventory applied).
public enum PlaybookTargets {
    /// `[relative playbook path: hosts]`, one `ansible-playbook -i <inv> <playbook> --list-hosts` per playbook,
    /// run from the project dir (its ansible.cfg applies). Throws `StatusError` if one fails.
    public static func load(tools: AnsibleTools, project: AnsibleProject) async throws -> [String: Set<String>] {
        var targets: [String: Set<String>] = [:]
        for playbook in project.playbooks {
            let (code, lines) = try await CommandRunner.run(tools.playbook, arguments: ["-i", project.inventory.path, playbook.path, "--list-hosts"],
                                                            workingDirectory: project.url)
            guard code == 0 else {
                throw StatusError(message: "ansible-playbook --list-hosts a échoué pour \(project.relativePath(playbook)) (code \(code)) :\n"
                                  + lines.joined(separator: "\n"))
            }
            targets[project.relativePath(playbook)] = parse(lines)
        }
        return targets
    }

    /// Union of the hosts listed under every `hosts (N):` line (one play each), stopping at the first line that is
    /// blank or not indented deeper (warnings on stderr start at column 0).
    public static func parse(_ lines: [String]) -> Set<String> {
        var hosts = Set<String>()
        var headerIndent: Int?
        for line in lines {
            let indent = line.prefix { $0 == " " }.count
            let text = line.trimmingCharacters(in: .whitespaces)
            if let h = headerIndent, !text.isEmpty, indent > h {
                hosts.insert(text)
                continue
            }
            headerIndent = text.hasPrefix("hosts (") && text.hasSuffix("):") ? indent : nil
        }
        return hosts
    }
}

public struct StatusError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}
