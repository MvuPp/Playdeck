import Foundation

/// Last real deployment of one playbook on one host.
public struct LedgerEntry: Codable, Sendable, Equatable {
    public var hash: String
    public var date: Date
    public var deployedBy: String

    public init(hash: String, date: Date, deployedBy: String = NSUserName()) {
        self.hash = hash; self.date = date; self.deployedBy = deployedBy
    }
}

/// Files added / modified / removed between two manifests.
public struct FileChanges: Sendable, Equatable {
    public var added: [String] = [], modified: [String] = [], removed: [String] = []
    public var isEmpty: Bool { added.isEmpty && modified.isEmpty && removed.isEmpty }
    public var count: Int { added.count + modified.count + removed.count }

    public init(from old: [String: String], to new: [String: String]) {
        added = new.keys.filter { old[$0] == nil }.sorted()
        removed = old.keys.filter { new[$0] == nil }.sorted()
        modified = new.keys.filter { old[$0] != nil && old[$0] != new[$0] }.sorted()
    }
}

/// The deploy record kept INSIDE the project, in `.playdeck/` (nothing is written on the hosts):
/// - `deployments.json`: host → playbook (relative path) → last real successful deployment (hash, date, user);
/// - `manifests/<hash>.json`: file → SHA-256 at that hash, to list what changed since a host was deployed.
/// Commit `.playdeck/` to share it with the team; only deployments made through the app are known.
public struct DeployLedger: Sendable {
    public static let directoryName = ".playdeck"
    public typealias Entries = [String: [String: LedgerEntry]]

    public let directory: URL

    public init(project: AnsibleProject) { directory = project.url.appendingPathComponent(Self.directoryName, isDirectory: true) }

    private var deploymentsURL: URL { directory.appendingPathComponent("deployments.json") }
    private func manifestURL(_ hash: String) -> URL { directory.appendingPathComponent("manifests/\(hash).json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]  // stable, readable diffs when committed
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Every recorded deployment; empty if the file does not exist yet. Throws if it exists but cannot be read or
    /// decoded (a git merge conflict, a newer format…): treating it as empty would hide every deployment and the next
    /// `record` would overwrite the team's history.
    public func load() throws -> Entries {
        guard FileManager.default.fileExists(atPath: deploymentsURL.path) else { return [:] }
        do {
            return try Self.decoder.decode(Entries.self, from: Data(contentsOf: deploymentsURL))
        } catch {
            throw StatusError(message: "\(Self.directoryName)/deployments.json est illisible (conflit git ?) : rien ne sera noté "
                              + "tant qu'il n'est pas réparé. \(error.localizedDescription)")
        }
    }

    /// Manifest saved for `hash`, nil if unknown.
    public func manifest(_ hash: String) -> [String: String]? {
        (try? Data(contentsOf: manifestURL(hash))).flatMap { try? Self.decoder.decode([String: String].self, from: $0) }
    }

    /// Records `playbook` as deployed at `hash` on `hosts`: re-read, merged and written under an exclusive lock
    /// (`flock` on `deployments.lock`), so two batches or two app instances never drop each other's entries.
    /// Refuses to write (throws) if the existing file is unreadable.
    public func record(hosts: [String], playbook: String, hash: String, manifest: [String: String], date: Date) throws {
        try FileManager.default.createDirectory(at: manifestURL(hash).deletingLastPathComponent(), withIntermediateDirectories: true)
        let ignore = directory.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) { try "deployments.lock\n".write(to: ignore, atomically: true, encoding: .utf8) }
        let fd = open(directory.appendingPathComponent("deployments.lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw StatusError(message: "verrou \(Self.directoryName)/deployments.lock impossible (errno \(errno))") }
        defer { close(fd) }  // closing releases the flock
        guard flock(fd, LOCK_EX) == 0 else { throw StatusError(message: "verrou \(Self.directoryName)/deployments.lock impossible (errno \(errno))") }
        if !FileManager.default.fileExists(atPath: manifestURL(hash).path) {
            try Self.encoder.encode(manifest).write(to: manifestURL(hash), options: .atomic)
        }
        var entries = try load()
        for host in hosts { entries[host, default: [:]][playbook] = LedgerEntry(hash: hash, date: date) }
        try Self.encoder.encode(entries).write(to: deploymentsURL, options: .atomic)
    }
}
