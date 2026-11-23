import Foundation

/// Paths of the three Ansible binaries, all in the same directory.
public struct AnsibleTools: Sendable, Equatable {
    public let directory: URL
    public var playbook: URL { directory.appendingPathComponent("ansible-playbook") }
    public var ansible: URL { directory.appendingPathComponent("ansible") }
    public var inventory: URL { directory.appendingPathComponent("ansible-inventory") }
}

public enum AnsibleLocator {
    /// UserDefaults key for the path chosen in Settings (dir or path to ansible-playbook).
    public static let settingsKey = "ansiblePath"

    /// Search order: saved path, standard dirs, then a login zsh (`command -v`).
    public static func locate(savedPath: String? = UserDefaults.standard.string(forKey: settingsKey)) -> AnsibleTools? {
        var candidates: [String] = []
        if let saved = savedPath?.trimmingCharacters(in: .whitespaces), !saved.isEmpty {
            let expanded = (saved as NSString).expandingTildeInPath
            candidates.append(expanded.hasSuffix("/ansible-playbook") ? (expanded as NSString).deletingLastPathComponent : expanded)
        }
        candidates += CommandRunner.extraPath
        for dir in candidates where isComplete(dir) {
            return AnsibleTools(directory: URL(fileURLWithPath: dir))
        }
        if let found = loginShellLookup(), isComplete((found as NSString).deletingLastPathComponent) {
            return AnsibleTools(directory: URL(fileURLWithPath: found).deletingLastPathComponent())
        }
        return nil
    }

    /// Output of `ansible --version` (first line is e.g. "ansible [core 2.17.0]").
    public static func version(_ tools: AnsibleTools) async throws -> String {
        let (code, lines) = try await CommandRunner.run(tools.ansible, arguments: ["--version"])
        guard code == 0 else { throw VersionError(exitCode: code, output: lines.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }

    public struct VersionError: Error, Sendable {
        public let exitCode: Int32
        public let output: String
    }

    private static func isComplete(_ dir: String) -> Bool {
        ["ansible-playbook", "ansible", "ansible-inventory"].allSatisfy {
            FileManager.default.isExecutableFile(atPath: dir + "/" + $0)
        }
    }

    private static func loginShellLookup() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v ansible-playbook"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // last line: login profiles may print noise before it
        let path = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return p.terminationStatus == 0 && path.hasPrefix("/") ? path : nil
    }
}
