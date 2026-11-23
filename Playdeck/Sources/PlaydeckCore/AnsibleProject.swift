import CryptoKit
import Foundation

public struct Host: Sendable, Hashable, Identifiable {
    public let name: String
    /// Direct groups from `ansible-inventory --list`, without `all` / `ungrouped`, sorted.
    public let groups: [String]
    public var id: String { name }
}

public enum ProjectError: Error, Equatable, LocalizedError {
    public enum Requirement: String, Sendable {
        case inventory = "un inventaire (clé `inventory` de ansible.cfg, inventory/, hosts.yml, hosts ou inventory.ini)"
        case playbook = "un playbook (.yml/.yaml à la racine, dans playbook/ ou playbooks/, avec `hosts:` au premier niveau)"
    }
    case notADirectory(String)
    case missing([Requirement])
    case inventoryFailed(code: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let path): "« \(path) » n'est pas un dossier."
        case .missing(let reqs): "Ce dossier n'est pas un projet Ansible. Il manque : " + reqs.map(\.rawValue).joined(separator: " ; ") + "."
        case .inventoryFailed(let code, let output): "ansible-inventory a échoué (code \(code)) :\n\(output)"
        }
    }
}

/// A validated Ansible project folder.
public struct AnsibleProject: Sendable {
    public let url: URL
    public let inventory: URL
    public let playbooks: [URL]

    public var name: String { url.lastPathComponent }

    /// Validates the folder; throws `ProjectError` listing what is missing.
    public init(url: URL) throws {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProjectError.notADirectory(url.path)
        }
        let inventory = Self.findInventory(in: url)
        let playbooks = Self.findPlaybooks(in: url)
        var missing: [ProjectError.Requirement] = []
        if inventory == nil { missing.append(.inventory) }
        if playbooks.isEmpty { missing.append(.playbook) }
        guard let inventory, missing.isEmpty else { throw ProjectError.missing(missing) }
        self.url = url
        self.inventory = inventory
        self.playbooks = playbooks
    }

    /// Path of a file relative to the project root (e.g. "playbook/audit.yml").
    public func relativePath(_ file: URL) -> String {
        String(file.standardizedFileURL.path.dropFirst(url.path.count + 1))
    }

    // MARK: - Validation

    static func findInventory(in dir: URL) -> URL? {
        let fm = FileManager.default
        if let cfg = try? String(contentsOf: dir.appendingPathComponent("ansible.cfg"), encoding: .utf8),
           let value = iniValue(cfg, section: "defaults", key: "inventory") {
            // shortcut: comma-separated inventory lists use only the first entry
            let first = value.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let expanded = (first as NSString).expandingTildeInPath
            let candidate = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : dir.appendingPathComponent(expanded)
            if fm.fileExists(atPath: candidate.path) { return candidate.standardizedFileURL }
        }
        return ["inventory", "hosts.yml", "hosts", "inventory.ini"]
            .map { dir.appendingPathComponent($0) }
            .first { fm.fileExists(atPath: $0.path) }
    }

    static func iniValue(_ text: String, section: String, key: String) -> String? {
        var current = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") { current = String(line.dropFirst().dropLast()); continue }
            guard current == section, !line.hasPrefix("#"), !line.hasPrefix(";"),
                  let eq = line.firstIndex(where: { $0 == "=" || $0 == ":" }),
                  line[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func findPlaybooks(in dir: URL) -> [URL] {
        let fm = FileManager.default
        return [dir, dir.appendingPathComponent("playbook"), dir.appendingPathComponent("playbooks")]
            .flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) }
            .filter { (try? String(contentsOf: $0, encoding: .utf8)).map(isPlaybook) ?? false }
            .map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
    }

    /// True if a top-level list item has a `hosts:` key (`- hosts:` or `  hosts:` inside a `- ` item).
    static func isPlaybook(_ yaml: String) -> Bool {
        // shortcut: assumes the standard 2-space item indent; upgrade to a YAML parser if odd layouts appear
        var inItem = false
        for line in yaml.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("- ") {
                inItem = true
                if line.dropFirst(2).trimmingCharacters(in: .whitespaces).hasPrefix("hosts:") { return true }
            } else if let first = line.first, first != " ", first != "#" {
                inItem = false
            } else if inItem, line.hasPrefix("  hosts:") {
                return true
            }
        }
        return false
    }

    // MARK: - Inventory

    /// Runs `ansible-inventory -i <inv> --list` from the project dir and returns hosts sorted by name.
    public func loadHosts(tools: AnsibleTools) async throws -> [Host] {
        let (code, lines) = try await CommandRunner.run(
            tools.inventory, arguments: ["-i", inventory.path, "--list"], workingDirectory: url)
        let output = lines.joined(separator: "\n")
        guard code == 0, let start = output.firstIndex(of: "{") else {
            throw ProjectError.inventoryFailed(code: code, output: output)
        }
        // stderr warnings are merged into the stream: parse from the first "{"
        return try Self.parseInventory(Data(output[start...].utf8))
    }

    static func parseInventory(_ data: Data) throws -> [Host] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var groups: [String: Set<String>] = [:]
        let meta = (json["_meta"] as? [String: Any])?["hostvars"] as? [String: Any] ?? [:]
        for name in meta.keys { groups[name, default: []] = [] }
        for (group, value) in json where group != "_meta" {
            for host in (value as? [String: Any])?["hosts"] as? [String] ?? [] {
                groups[host, default: []].formUnion(group == "all" || group == "ungrouped" ? [] : [group])
            }
        }
        return groups.map { Host(name: $0.key, groups: $0.value.sorted()) }.sorted { $0.name < $1.name }
    }

    // MARK: - Version

    /// `git rev-parse --short HEAD` (+ `-dirty`), nil outside git or before the first commit. Display only.
    public func gitCommit() async -> String? {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        guard let (code, lines) = try? await CommandRunner.run(git, arguments: ["rev-parse", "--short", "HEAD"], workingDirectory: url),
              code == 0, let sha = lines.first, !sha.isEmpty else { return nil }
        let status = try? await CommandRunner.run(git, arguments: ["status", "--porcelain"], workingDirectory: url)
        let dirty = status.map { $0.code == 0 && $0.lines.contains { !$0.isEmpty } } ?? false
        return sha + (dirty ? "-dirty" : "")
    }

    /// Relative path → SHA-256 (hex) of every file of the project. See `scan`.
    public func manifest() -> [String: String] { scan().files }

    /// Walks the project and hashes every file. Excluded: `.git` and `.playdeck/` (anywhere), `logs/` at the root,
    /// ansible.cfg's `log_path` (rewritten by every Ansible command), `*.retry`, `.DS_Store` (Finder writes it just by
    /// browsing). Symlinks are followed (a symlinked role is code too), with a guard against loops.
    /// Unreadable files/dirs are listed in `unreadable` (a file is hashed as « unreadable », so it still counts).
    /// `cache`: files whose size and modification date did not change are not re-read.
    public func scan(reusing cache: [String: FileStamp] = [:]) -> ManifestScan {
        var result = ManifestScan()
        let logPath = Self.iniValue((try? String(contentsOf: url.appendingPathComponent("ansible.cfg"), encoding: .utf8)) ?? "",
                                    section: "defaults", key: "log_path")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, relativeTo: url).standardizedFileURL.path }
        var visited: Set<String> = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        func walk(_ dir: URL, _ prefix: String) {
            guard visited.insert(dir.resolvingSymlinksInPath().path).inserted else { return }  // symlink loop
            guard let children = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else {
                result.unreadable.append(prefix.isEmpty ? "." : String(prefix.dropLast()))
                return
            }
            for child in children {
                let name = child.lastPathComponent
                let rel = prefix + name
                if name == ".git" || name == DeployLedger.directoryName || (prefix.isEmpty && name == "logs") { continue }
                if name == ".DS_Store" || name.hasSuffix(".retry") || child.standardizedFileURL.path == logPath { continue }
                let target = child.resolvingSymlinksInPath()
                guard let values = try? target.resourceValues(forKeys: Set(keys)) else { continue }  // dangling symlink
                if values.isDirectory == true {
                    walk(target, rel + "/")
                } else if values.isRegularFile == true {
                    let stamp = FileStamp(size: values.fileSize ?? -1, modified: values.contentModificationDate ?? .distantPast, hash: "")
                    if let cached = cache[rel], cached.size == stamp.size, cached.modified == stamp.modified {
                        result.files[rel] = cached.hash
                        result.stamps[rel] = cached
                    } else if let hash = Self.sha256(of: target) {
                        result.files[rel] = hash
                        result.stamps[rel] = FileStamp(size: stamp.size, modified: stamp.modified, hash: hash)
                    } else {
                        result.files[rel] = "unreadable"
                        result.unreadable.append(rel)
                    }
                }
            }
        }
        walk(url, "")
        result.unreadable.sort()
        return result
    }

    /// Streams the file (1 MB chunks): a big binary in files/ is never loaded at once.
    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Deploy hash: first 12 hex chars of a SHA-256 over the sorted (path, file hash) pairs of `manifest`.
    public static func hash(_ manifest: [String: String]) -> String {
        var hasher = SHA256()
        for path in manifest.keys.sorted() { hasher.update(data: Data((path + "\0" + manifest[path]! + "\n").utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    public func contentHash() -> String { Self.hash(manifest()) }

}

/// Size + modification date of a file and its hash, to skip re-reading unchanged files.
public struct FileStamp: Sendable, Equatable {
    public let size: Int
    public let modified: Date
    public let hash: String
}

public struct ManifestScan: Sendable {
    public var files: [String: String] = [:]
    public var stamps: [String: FileStamp] = [:]
    public var unreadable: [String] = []
    public var hash: String { AnsibleProject.hash(files) }
}
