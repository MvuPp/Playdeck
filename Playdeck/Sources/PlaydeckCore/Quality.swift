import Foundation

/// Severity of an ansible-lint finding; `points` feed the grade.
public enum LintSeverity: String, Sendable, Comparable, CaseIterable {
    /// SARIF rule level `note`, or a non-fatal finding (result level `warning`, e.g. `warn_list`).
    case low
    /// SARIF rule level `warning` (ansible-lint rule severity MEDIUM / LOW / VERY_LOW).
    case medium
    /// SARIF rule level `error` (ansible-lint rule severity VERY_HIGH / HIGH).
    case high

    public var points: Int { switch self { case .low: 1; case .medium: 2; case .high: 5 } }
    public static func < (a: Self, b: Self) -> Bool { a.points < b.points }
}

/// One ansible-lint finding. `file` is relative to the project root.
public struct LintIssue: Sendable, Hashable {
    /// e.g. `fqcn[action-core]`, `name[missing]`, `syntax-check[unknown-module]`.
    public let rule: String
    public let severity: LintSeverity
    public let file: String
    public let line: Int?
    /// ansible-lint's text for this finding (often the task, e.g. « Task/Handler: command ls »).
    public let message: String
    /// Rule documentation.
    public let helpURL: String?

    public init(rule: String, severity: LintSeverity, file: String, line: Int?, message: String, helpURL: String? = nil) {
        self.rule = rule; self.severity = severity; self.file = file; self.line = line; self.message = message; self.helpURL = helpURL
    }

    /// Syntax / load errors: the file cannot even be run.
    public var isFatal: Bool { ["syntax-check", "load-failure", "internal-error"].contains { rule.hasPrefix($0) } }
}

public enum Grade: String, Sendable, Comparable, CaseIterable {
    case A, B, C, D, E, F
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// ansible-lint result of one project at one content hash.
public struct LintReport: Sendable, Equatable {
    /// `AnsibleProject.hash(manifest)` the report was computed for.
    public let hash: String
    /// Every finding, sorted by file then line.
    public let issues: [LintIssue]
    /// Playbook (relative path) → its findings: its own file + the roles it references (see `Quality.attribute`).
    /// Every playbook of the project has an entry (possibly empty).
    public let playbookIssues: [String: [LintIssue]]

    public init(hash: String, issues: [LintIssue], playbookIssues: [String: [LintIssue]]) {
        self.hash = hash; self.issues = issues; self.playbookIssues = playbookIssues
    }

    /// All findings: roles, vars and unreferenced files included.
    /// `syntaxOK: false` when a playbook of the project failed `ansible-playbook --syntax-check`: it cannot run → F,
    /// whatever ansible-lint (with its own ansible-core) found.
    public func projectGrade(syntaxOK: Bool = true) -> Grade { syntaxOK ? Quality.grade(issues) : .F }
    public func grade(forPlaybook playbook: String, syntaxOK: Bool = true) -> Grade {
        syntaxOK ? Quality.grade(playbookIssues[playbook] ?? []) : .F
    }
    public var byFile: [String: [LintIssue]] { Dictionary(grouping: issues, by: \.file) }
}

/// `ansible-playbook --syntax-check` of one playbook.
public struct SyntaxCheckResult: Sendable, Equatable {
    /// Relative path.
    public let playbook: String
    public let ok: Bool
    /// ansible-playbook's output when it failed (stdout + stderr), "" when ok.
    public let message: String
}

public enum QualityError: Error, Equatable, LocalizedError {
    case lintNotInstalled
    case lintFailed(code: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .lintNotInstalled: "ansible-lint n'est pas installé (brew install ansible-lint)."
        case .lintFailed(let code, let output): "ansible-lint a échoué (code \(code)) :\n\(output)"
        }
    }
}

/// Pure parts: SARIF parsing, grading, attribution to playbooks.
public enum Quality {
    /// Arguments of ansible-lint (run from the project dir): SARIF on stdout, no network, nothing written.
    public static let lintArguments = ["-f", "sarif", "--nocolor", "--offline"]

    /// Environment of analysis runs: Ansible's `log_path` not written (nothing added to the project's log).
    public static let analysisEnvironment = ["ANSIBLE_LOG_PATH": "/dev/null", "NO_COLOR": "1"]

    /// site-packages of Playdeck's Ansible when it holds `ansible_collections` (pip / Homebrew `ansible` package).
    /// Given to ansible-lint, whose own ansible-core lacks them (else `syntax-check[unknown-module]` for e.g. community.docker).
    public static func collectionsDirectory(_ tools: AnsibleTools) -> String? {
        let lib = tools.playbook.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")
        let pythons = ((try? FileManager.default.contentsOfDirectory(atPath: lib.path)) ?? []).filter { $0.hasPrefix("python") }.sorted()
        return pythons.map { lib.path + "/\($0)/site-packages" }.first { FileManager.default.fileExists(atPath: $0 + "/ansible_collections") }
    }

    /// Grade from the sum of `severity.points`: A = 0, B ≤ 4, C ≤ 14, D ≤ 29, E ≤ 49, F ≥ 50 or any fatal issue
    /// (`syntax-check…`, `load-failure…`, `internal-error`). Absolute count, not scaled by file size.
    public static func grade(_ issues: [LintIssue]) -> Grade {
        if issues.contains(where: \.isFatal) { return .F }
        let points = issues.reduce(0) { $0 + $1.severity.points }
        switch points {
        case 0: return .A
        case ...4: return .B
        case ...14: return .C
        case ...29: return .D
        case ...49: return .E
        default: return .F
        }
    }

    /// Parses `ansible-lint -f sarif` stdout. Severity = rule level (`error` high, `warning` medium, `note` low),
    /// lowered to `.low` when the finding itself is not an error (warning-only rules).
    public static func parseSARIF(_ data: Data) throws -> [LintIssue] {
        let log = try JSONDecoder().decode(SARIF.self, from: data)
        return log.runs.flatMap { run in
            let ruleLevel = Dictionary(run.tool.driver.rules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return run.results.map { r in
                let rule = ruleLevel[r.ruleId]
                let level = r.level == "error" ? rule?.defaultConfiguration?.level : "note"
                let severity: LintSeverity = level == "error" ? .high : level == "note" ? .low : .medium
                let loc = r.locations.first?.physicalLocation
                return LintIssue(rule: r.ruleId, severity: severity, file: loc?.artifactLocation.uri ?? "", line: loc?.region?.startLine,
                                 message: r.message.text, helpURL: rule?.helpUri)
            }
        }
        .sorted { ($0.file, $0.line ?? 0) < ($1.file, $1.line ?? 0) }
    }

    /// Findings of each playbook (relative path → its YAML text): those in the playbook's own file, plus those in a
    /// role it references by name (`roles:` list, `include_role` / `import_role` `name:`; see `referencedRoles`).
    /// A file belongs to role R if its path contains `roles/R/`. Not followed: role dependencies (meta/main.yml),
    /// `include_tasks` / `import_playbook` / `vars_files`: those findings only count for the project.
    public static func attribute(_ issues: [LintIssue], playbooks: [String: String]) -> [String: [LintIssue]] {
        playbooks.reduce(into: [:]) { out, entry in
            let roles = referencedRoles(entry.value)
            out[entry.key] = issues.filter { $0.file == entry.key || roleName(ofFile: $0.file).map(roles.contains) == true }
        }
    }

    /// Role owning a file: the component after the last `roles/` (`roles/web/tasks/main.yml` → `web`).
    public static func roleName(ofFile path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let i = parts.lastIndex(of: "roles"), i + 2 < parts.count else { return nil }
        return parts[i + 1]
    }

    /// Role names a playbook references, read as text: items of a `roles:` list (`- web`, `- role: web`,
    /// `- { role: web }`, `- name: web`) and the `name:` under `include_role:` / `import_role:` (FQCN or not).
    /// A collection role `ns.col.web` or a path `roles/web` gives `web`.
    public static func referencedRoles(_ yaml: String) -> Set<String> {
        // shortcut: indentation-based reading, no YAML parser; flow-style lists (`roles: [a, b]`) are missed
        enum Block { case roles, include }
        var block: (kind: Block, indent: Int)?
        var found: Set<String> = []
        func add(_ raw: Substring) {
            let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard !value.isEmpty, !value.contains("{{") else { return }
            let last = value.split(separator: "/").last.map(String.init) ?? value
            found.insert(last.split(separator: ".").last.map(String.init) ?? last)
        }
        func value(of key: String, in text: Substring) -> Substring? {
            guard let r = text.range(of: key + ":") else { return nil }
            let rest = text[r.upperBound...]
            return rest.prefix { $0 != "," && $0 != "}" && $0 != "#" }
        }
        for raw in yaml.split(whereSeparator: \.isNewline) {
            let indent = raw.prefix { $0 == " " }.count
            let text = raw.drop { $0 == " " }
            if text.isEmpty || text.hasPrefix("#") { continue }
            if let b = block, indent < b.indent || (indent == b.indent && !(b.kind == .roles && text.hasPrefix("- "))) { block = nil }
            if let b = block {
                let item = text.hasPrefix("- ") ? text.dropFirst(2).drop { $0 == " " } : text
                switch b.kind {
                case .roles where item.hasPrefix("{"):
                    if let v = value(of: "role", in: item) ?? value(of: "name", in: item) { add(v) }
                case .roles where text.hasPrefix("- ") && !item.contains(":"):
                    add(item)
                case .roles, .include:
                    for key in ["role", "name"] where item.hasPrefix(key + ":") { add(value(of: key, in: item)!) }
                }
                continue
            }
            let key = (text.hasPrefix("- ") ? text.dropFirst(2).drop { $0 == " " } : text)
            if key == "roles:" { block = (.roles, indent) }
            else if key.hasSuffix("include_role:") || key.hasSuffix("import_role:") {
                // `- include_role:` : its keys sit 2 columns right of the dash, the next task at the dash
                block = (.include, indent + (text.hasPrefix("- ") ? 1 : 0))
            }
        }
        return found
    }

    private struct SARIF: Decodable {
        struct Run: Decodable { let tool: Tool; let results: [Result] }
        struct Tool: Decodable { let driver: Driver }
        struct Driver: Decodable { let rules: [Rule] }
        struct Rule: Decodable { let id: String; let defaultConfiguration: Config?; let helpUri: String? }
        struct Config: Decodable { let level: String? }
        struct Result: Decodable { let ruleId: String; let level: String?; let message: Message; let locations: [Location] }
        struct Message: Decodable { let text: String }
        struct Location: Decodable { let physicalLocation: Physical? }
        struct Physical: Decodable { let artifactLocation: Artifact; let region: Region? }
        struct Artifact: Decodable { let uri: String }
        struct Region: Decodable { let startLine: Int? }
        let runs: [Run]
    }
}

/// Runs ansible-lint and `--syntax-check` off the main thread, cached per project path + content hash
/// (same hash → no new run; concurrent calls for the same hash share one run).
public actor QualityService {
    public let tools: AnsibleTools
    /// nil: ansible-lint not installed (`lint` throws `.lintNotInstalled`). Get it with `AnsibleLocator.locateLint()` off the main thread.
    public let lintExecutable: URL?
    private var lintCache: [String: (hash: String, task: Task<LintReport, Error>)] = [:]
    private var syntaxCache: [String: (hash: String, task: Task<[SyntaxCheckResult], Never>)] = [:]

    public init(tools: AnsibleTools, lint: URL?) {
        self.tools = tools
        self.lintExecutable = lint
    }

    /// `ansible-lint -f sarif --nocolor --offline` from the project dir, with `ANSIBLE_COLLECTIONS_PATH` = Playdeck's
    /// Ansible collections (`Quality.collectionsDirectory`) + the defaults, and no Ansible log written. Exit codes ≠ 0 are normal when issues are
    /// found: only unparsable stdout is an error. `hash` nil = computed from the files (`contentHash()`).
    public func lint(_ project: AnsibleProject, hash: String? = nil) async throws -> LintReport {
        guard let lint = lintExecutable else { throw QualityError.lintNotInstalled }
        let hash = hash ?? project.contentHash()
        let key = project.url.path
        if let cached = lintCache[key], cached.hash == hash { return try await cached.task.value }
        var env = Quality.analysisEnvironment
        let home = NSHomeDirectory()
        env["ANSIBLE_COLLECTIONS_PATH"] = ([Quality.collectionsDirectory(tools)].compactMap { $0 }
            + [home + "/.ansible/collections", "/usr/share/ansible/collections"]).joined(separator: ":")
        let task = Task.detached { [env] () throws -> LintReport in
            let (code, stdout, stderr) = try await CommandRunner.capture(lint, arguments: Quality.lintArguments,
                                                                         workingDirectory: project.url, environment: env)
            guard let issues = try? Quality.parseSARIF(stdout) else {
                throw QualityError.lintFailed(code: code, output: stderr.split(separator: "\n").suffix(20).joined(separator: "\n"))
            }
            var texts: [String: String] = [:]
            for pb in project.playbooks { texts[project.relativePath(pb)] = (try? String(contentsOf: pb, encoding: .utf8)) ?? "" }
            return LintReport(hash: hash, issues: issues, playbookIssues: Quality.attribute(issues, playbooks: texts))
        }
        lintCache[key] = (hash, task)
        do { return try await task.value } catch {
            if lintCache[key]?.hash == hash { lintCache[key] = nil }  // a failure is retried next time
            throw error
        }
    }

    /// `ansible-playbook --syntax-check -i <inv> <playbook>` for every playbook (in parallel), from the project dir,
    /// with Playdeck's Ansible. Result in `project.playbooks` order.
    public func syntaxCheck(_ project: AnsibleProject, hash: String? = nil) async -> [SyntaxCheckResult] {
        let hash = hash ?? project.contentHash()
        let key = project.url.path
        if let cached = syntaxCache[key], cached.hash == hash { return await cached.task.value }
        let playbook = tools.playbook
        let task = Task.detached { () -> [SyntaxCheckResult] in
            await withTaskGroup(of: (Int, SyntaxCheckResult).self) { group in
                for (i, pb) in project.playbooks.enumerated() {
                    group.addTask {
                        let rel = project.relativePath(pb)
                        do {
                            let (code, lines) = try await CommandRunner.run(
                                playbook, arguments: ["--syntax-check", "-i", project.inventory.path, pb.path], workingDirectory: project.url,
                                environment: Quality.analysisEnvironment)
                            let text = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
                            return (i, SyntaxCheckResult(playbook: rel, ok: code == 0, message: code == 0 ? "" : text))
                        } catch {
                            return (i, SyntaxCheckResult(playbook: rel, ok: false, message: error.localizedDescription))
                        }
                    }
                }
                var out: [(Int, SyntaxCheckResult)] = []
                for await r in group { out.append(r) }
                return out.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }
        syntaxCache[key] = (hash, task)
        return await task.value
    }
}
