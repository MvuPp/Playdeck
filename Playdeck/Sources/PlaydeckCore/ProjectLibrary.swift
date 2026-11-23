import Foundation

/// Folders added by the user (persisted in UserDefaults) and the Ansible projects they contain.
public struct ProjectLibrary {
    public static let key = "projectFolders"
    private let defaults: UserDefaults

    /// Tests pass `UserDefaults(suiteName:)` so the real defaults are never touched.
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Added folders, in insertion order.
    public var folders: [URL] { (defaults.stringArray(forKey: Self.key) ?? []).map { URL(fileURLWithPath: $0) } }

    /// Adds a folder (no-op if already there, compared by standardized path).
    public func add(_ folder: URL) {
        let paths = folders.map(\.path)
        let path = folder.standardizedFileURL.path
        if !paths.contains(path) { defaults.set(paths + [path], forKey: Self.key) }
    }

    public func remove(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        defaults.set(folders.map(\.path).filter { $0 != path }, forKey: Self.key)
    }

    /// Re-scans every folder; a project reachable from two folders appears once (first folder wins).
    public func projects() -> [AnsibleProject] { projectsByFolder().flatMap(\.projects) }

    /// Same as `projects()`, grouped by added folder (a folder may end up with no project).
    public func projectsByFolder() -> [(folder: URL, projects: [AnsibleProject])] {
        var seen = Set<String>()
        return folders.map { folder in (folder, Self.scan(folder).filter { seen.insert($0.url.path).inserted }) }
    }

    /// The folder itself if it is a project, else its valid direct subfolders (sorted by name, hidden ones skipped).
    public static func scan(_ folder: URL) -> [AnsibleProject] {
        if let project = try? AnsibleProject(url: folder) { return [project] }
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                     options: .skipsHiddenFiles)) ?? []
        return children.compactMap { try? AnsibleProject(url: $0) }.sorted { $0.name < $1.name }
    }
}
