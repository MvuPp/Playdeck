import Foundation

/// One `ansible-playbook` execution, saved as JSON whatever its outcome (success, failure, cancel).
public struct Run: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var date: Date
    public var projectPath: String
    /// Path relative to the project (e.g. `playbooks/site.yml`).
    public var playbook: String
    public var version: String
    public var hosts: [String]
    public var checkMode: Bool
    public var exitCode: Int32
    public var cancelled: Bool
    /// Per-host counters; `HostResult.status` is derived from them.
    public var results: [HostResult]
    public var log: [String]
    /// Set when recording the hash in `.playdeck/` failed (the deployment itself is not failed for that).
    public var ledgerError: String?
    /// Shared by the runs of one « tout déployer » (nil for a single-playbook deploy and for pre-4bis runs).
    public var batchID: UUID?
    /// -e / tags / --diff / verbosity used (nil = none, and for older runs).
    public var options: DeployOptions?
    /// When ansible-playbook ended (nil for runs saved before Phase 6).
    public var endDate: Date?

    public init(id: UUID = UUID(), date: Date, projectPath: String, playbook: String, version: String, hosts: [String],
                checkMode: Bool, exitCode: Int32, cancelled: Bool, results: [HostResult], log: [String], ledgerError: String? = nil,
                batchID: UUID? = nil, options: DeployOptions? = nil, endDate: Date? = nil) {
        self.id = id; self.date = date; self.projectPath = projectPath; self.playbook = playbook; self.version = version
        self.hosts = hosts; self.checkMode = checkMode; self.exitCode = exitCode; self.cancelled = cancelled
        self.results = results; self.log = log; self.ledgerError = ledgerError; self.batchID = batchID
        self.options = options; self.endDate = endDate
    }

    public var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }
}

/// One JSON file per run in `<directory>/<date>-<id>.json`.
public struct RunStore: Sendable {
    public static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Playdeck/runs", isDirectory: true)

    public let directory: URL

    public init(directory: URL = RunStore.defaultDirectory) { self.directory = directory }

    @discardableResult
    public func save(_ run: Run) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: run.date).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(stamp)-\(run.id.uuidString).json")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(run).write(to: url, options: .atomic)
        return url
    }

    /// Runs grouped by `batchID` (a run without one is alone), groups in order of first appearance.
    public static func batches(_ runs: [Run]) -> [[Run]] {
        var groups: [[Run]] = []
        var index: [UUID: Int] = [:]
        for run in runs {
            if let id = run.batchID, let i = index[id] { groups[i].append(run); continue }
            if let id = run.batchID { index[id] = groups.count }
            groups.append([run])
        }
        return groups
    }

    /// All runs, newest first. Unreadable files are skipped.
    public func load() -> [Run] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(Run.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }
}
