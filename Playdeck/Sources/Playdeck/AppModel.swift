import PlaydeckCore
import Foundation
import Observation

/// What the sidebar shows in the center.
enum SidebarItem: Hashable {
    case overview, settings, history
    case project(String)  // project path
}

/// A deployment waiting for the user's confirmation.
struct PendingDeploy {
    let project: ProjectModel
    let playbooks: [URL]
    let hosts: [String]
    let check: Bool
    let options: DeployOptions
    /// Targets as shown in the confirmation: the batch runs exactly this plan even if `--list-hosts` finishes meanwhile.
    let targets: [String: Set<String>]?
    let steps: [BatchStep]
}

/// The single running (or last) batch: progress and log.
@Observable @MainActor final class BatchProgress {
    let projectPath: String
    let projectName: String
    let check: Bool
    let deployment: BatchDeployment
    var index = 0
    var count: Int
    var playbook = ""
    var finished = 0
    var log: [String] = []
    var running = true

    init(project: ProjectModel, check: Bool, count: Int, deployment: BatchDeployment) {
        projectPath = project.id; projectName = project.project.name
        self.check = check; self.count = count; self.deployment = deployment
    }
}

/// One project of the library: hosts, hash, targets, deploy record (.playdeck/), selection.
@Observable @MainActor final class ProjectModel: Identifiable {
    let project: AnsibleProject
    nonisolated var id: String { project.url.path }
    var hosts: [PlaydeckCore.Host] = [] { didSet { recompute() } }
    var version = "" { didSet { recompute() } }
    /// git commit (+ -dirty) for display; nil outside git. The deploy hash is `version`.
    var gitCommit: String?
    /// nil until `--list-hosts` has run (or if it failed): every playbook then applies to every host.
    var targets: [String: Set<String>]? { didSet { recompute() } }
    /// What `.playdeck/deployments.json` says was deployed on each host.
    var ledger: DeployLedger.Entries = [:] { didSet { recompute() } }
    /// file → SHA-256 of the current code (the hash `version` is derived from it).
    private(set) var manifest: [String: String] = [:]
    /// Size/date/hash per file: unchanged files are not re-read by the periodic rehash.
    @ObservationIgnored private var stamps: [String: FileStamp] = [:]
    /// Files or folders that could not be read (they make the hash unreliable).
    private(set) var unreadable: [String] = []
    /// `.playdeck/deployments.json` exists but cannot be read: states unknown, nothing will be recorded.
    private(set) var ledgerError: String?
    // Filled while views read it: must not be observed (no state change during a view update).
    @ObservationIgnored private var changesCache: [String: FileChanges] = [:]
    var runs: [Run] = []
    /// Checked playbooks (relative paths); all by default.
    var checked: Set<String> { didSet { recompute() } }
    var selection: Set<String> = []
    var group = ""  // "" = all groups
    /// -e / tags / --diff / verbosity, edited in the right panel, remembered per project.
    var options: DeployOptions {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(options), forKey: "deployOptions." + id) }
    }
    /// « Demander le mot de passe sudo » at confirmation (off by default). The flag only, never the password.
    var askBecomePassword: Bool {
        didSet { UserDefaults.standard.set(askBecomePassword, forKey: "askBecomePassword." + id) }
    }
    /// Whether the Keychain holds this project's vault password (nil = not checked yet). Never the value.
    var vaultSaved: Bool?
    var loading = false
    var error: String?

    /// host → playbook → status, only for the playbooks targeting the host.
    private(set) var matrix: [String: [String: HostDeployStatus]] = [:]
    /// Worst status per host over the checked playbooks.
    private(set) var perHost: [String: HostDeployStatus] = [:]
    private(set) var counts = StatusCounts()

    init(_ project: AnsibleProject) {
        self.project = project
        checked = Set(project.playbooks.map(project.relativePath))
        options = UserDefaults.standard.data(forKey: "deployOptions." + project.url.path)
            .flatMap { try? JSONDecoder().decode(DeployOptions.self, from: $0) } ?? DeployOptions()
        askBecomePassword = UserDefaults.standard.bool(forKey: "askBecomePassword." + project.url.path)
    }

    var playbookNames: [String] { project.playbooks.map(project.relativePath) }
    var groups: [String] { Set(hosts.flatMap(\.groups)).sorted() }
    var visibleHosts: [PlaydeckCore.Host] { group.isEmpty ? hosts : hosts.filter { $0.groups.contains(group) } }
    var selectedHosts: [String] { hosts.map(\.name).filter(selection.contains) }
    var checkedPlaybooks: [URL] { project.playbooks.filter { checked.contains(project.relativePath($0)) } }

    private func recompute() {
        matrix = StatusService.statuses(ledger: ledger, hosts: hosts.map(\.name), playbooks: playbookNames, targets: targets, version: version)
        perHost = StatusService.perHost(matrix, playbooks: checked)
        counts = StatusCounts(perHost.values)
    }

    func load(tools: AnsibleTools) async {
        loading = true
        defer { loading = false }
        error = nil
        let p = project
        async let scan = Task.detached { p.scan() }.value
        async let git = project.gitCommit()
        do { hosts = try await project.loadHosts(tools: tools) } catch { self.error = error.localizedDescription }
        do { targets = try await PlaybookTargets.load(tools: tools, project: project) } catch {
            self.error = [self.error, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
        }
        let result = await scan
        apply(result, hash: result.hash)
        gitCommit = await git
        reloadLedger()
    }

    private func apply(_ scan: ManifestScan, hash: String) {
        stamps = scan.stamps
        if scan.unreadable != unreadable { unreadable = scan.unreadable }
        guard hash != version else { return }
        manifest = scan.files
        changesCache = [:]
        version = hash
    }

    /// Re-reads `.playdeck/` (after a deploy, or a `git pull` that brought teammates' deployments).
    func reloadLedger() {
        do {
            let fresh = try DeployLedger(project: project).load()
            if fresh != ledger { ledger = fresh }
            if ledgerError != nil { ledgerError = nil }
        } catch {
            if ledgerError != error.localizedDescription { ledgerError = error.localizedDescription }
        }
    }

    /// Files changed since the code was at `hash` (nil if that hash's manifest was not recorded).
    func changes(since hash: String) -> FileChanges? {
        if let cached = changesCache[hash] { return cached }
        guard let old = DeployLedger(project: project).manifest(hash) else { return nil }
        let c = FileChanges(from: old, to: manifest)
        changesCache[hash] = c
        return c
    }

    /// Re-hashes the files: on a change, every host whose recorded hash differs becomes « en retard ».
    func rehash() async {
        guard !loading, !version.isEmpty else { return }
        reloadLedger()
        let (p, cache, old) = (project, stamps, version)
        // Scan AND hash off the main thread; only changed files are re-read.
        let (scan, hash) = await Task.detached { let s = p.scan(reusing: cache); return (s, s.hash) }.value
        apply(scan, hash: hash)
        if hash != old { gitCommit = await project.gitCommit() }
    }

    func selectBehind() { selection.formUnion(perHost.filter { $0.value.state.isBehind }.map(\.key)) }
}

@Observable @MainActor final class AppModel {
    /// The live model, for the app delegate (quit while a batch runs).
    @ObservationIgnored static weak var current: AppModel?

    let tools: AnsibleTools
    let ansibleVersion: String
    private let library = ProjectLibrary()
    var folders: [(folder: URL, projects: [ProjectModel])] = []
    var selection: SidebarItem? = .overview
    var historyFilter = ""  // project path, "" = all
    var runs: [Run] = []
    var check = AppSettings.defaultCheck
    var pending: PendingDeploy?
    /// sudo password typed in the confirmation; memory only, cleared as soon as the batch starts or is cancelled.
    var becomePassword = ""
    /// Per-project ansible-vault passwords (account = project path).
    let passwords: any PasswordStore = Keychain()
    var batch: BatchProgress?
    var showLog = true
    /// Between « confirm » and the batch start (keychain read): counts as running.
    private var starting = false

    init(tools: AnsibleTools, ansibleVersion: String) {
        self.tools = tools
        self.ansibleVersion = ansibleVersion
        // One-time import of the pre-4bis « Récents » list.
        if library.folders.isEmpty, let data = UserDefaults.standard.data(forKey: "recentProjects"),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            paths.reversed().forEach { library.add(URL(fileURLWithPath: $0)) }
        }
        Self.current = self
        rescan()
        reloadRuns()
        // Code watch; settings re-read each turn. Weak: the loop ends if this model is ever released.
        // shortcut: walks every folder each turn (unchanged files are not re-read), switch to FSEvents if projects get huge.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(AppSettings.watchInterval))
                guard let self else { return }
                if AppSettings.watchCode { for p in self.projects { await p.rehash() } }
            }
        }
    }

    var projects: [ProjectModel] { folders.flatMap(\.projects) }
    var running: Bool { starting || batch?.running == true }
    var totalCounts: StatusCounts { projects.map(\.counts).reduce(StatusCounts(), +) }

    func project(_ path: String) -> ProjectModel? { projects.first { $0.id == path } }

    /// Re-scans the folders, keeping the already loaded projects.
    func rescan() {
        let old = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        folders = library.projectsByFolder().map { group in
            (group.folder, group.projects.map { old[$0.url.path] ?? ProjectModel($0) })
        }
        for p in projects where old[p.id] == nil {
            p.runs = runs.filter { $0.projectPath == p.id }
            Task { await p.load(tools: tools) }
        }
        if case .project(let path)? = selection, project(path) == nil { selection = .overview }
    }

    func reloadAll() {
        for p in projects { Task { await p.load(tools: tools) } }
    }

    func add(_ folder: URL) {
        library.add(folder)
        rescan()
        // Jump to the first project found, if any.
        if let first = ProjectLibrary.scan(folder).first { selection = .project(first.url.path) }
    }

    func remove(_ folder: URL) {
        library.remove(folder)
        rescan()
    }

    /// Decodes the history off the main thread (runs hold full logs).
    func reloadRuns() {
        Task {
            let loaded = await Task.detached { RunStore().load() }.value
            runs = loaded
            for p in projects { p.runs = loaded.filter { $0.projectPath == p.id } }
        }
    }

    /// Asks for confirmation; `allPlaybooks` = « Tout déployer ».
    func requestDeploy(_ p: ProjectModel, allPlaybooks: Bool) {
        guard !running, !p.selectedHosts.isEmpty else { return }
        if allPlaybooks { p.checked = Set(p.playbookNames) }
        let playbooks = p.checkedPlaybooks
        pending = PendingDeploy(project: p, playbooks: playbooks, hosts: p.selectedHosts, check: check, options: p.options,
                                targets: p.targets, steps: BatchDeployService.plan(playbooks: playbooks.map(p.project.relativePath), hosts: p.selectedHosts, targets: p.targets))
    }

    func cancelPending() {
        pending = nil
        becomePassword = ""
    }

    func confirm() {
        guard let request = pending, !running else { return }
        let p = request.project
        let become = p.askBecomePassword ? becomePassword : nil
        cancelPending()
        starting = true
        Task {
            // Keychain read off the main thread: an unsigned app may get a macOS access prompt.
            let (store, path) = (passwords, p.id)
            let vault = await Task.detached { store.password(for: path) }.value
            start(request, secrets: DeploySecrets(vaultPassword: vault, becomePassword: become))
            starting = false
        }
    }

    private func start(_ request: PendingDeploy, secrets: DeploySecrets) {
        let p = request.project
        let deployment = BatchDeployService.start(tools: tools, project: p.project, playbooks: request.playbooks, hosts: request.hosts,
                                                  targets: request.targets, check: request.check,
                                                  options: request.options, secrets: secrets)
        let progress = BatchProgress(project: p, check: request.check, count: request.playbooks.count, deployment: deployment)
        batch = progress
        showLog = true
        Task {
            // Log lines are flushed to the UI at most every 100 ms (-vvvv can emit thousands per second).
            var buffer: [String] = []
            var lastFlush = Date()
            @MainActor func flush() { progress.log.append(contentsOf: buffer); buffer.removeAll(); lastFlush = Date() }
            for await event in deployment.events {
                if case .line(let line) = event {
                    buffer.append(line)
                    if Date().timeIntervalSince(lastFlush) >= 0.1 { flush() }
                    continue
                }
                flush()
                switch event {
                case .line: break
                case let .playbookStarted(index, count, playbook, _):
                    (progress.index, progress.count, progress.playbook) = (index, count, playbook)
                case let .playbookSkipped(index, count, playbook):
                    (progress.index, progress.count, progress.playbook) = (index, count, playbook)
                    progress.finished += 1
                case let .playbookFinished(_, run):
                    progress.finished += 1
                    runs.insert(run, at: 0)
                    p.runs.insert(run, at: 0)
                }
            }
            flush()
            let runs = await deployment.result()
            if runs.isEmpty, deployment.isCancelled == false, request.steps.contains(where: { !$0.hosts.isEmpty }) {
                p.error = progress.log.last  // ansible-playbook could not start
            }
            Notifier.batchFinished(projectName: progress.projectName, check: request.check, runs: runs, cancelled: deployment.isCancelled)
            progress.running = false
            p.reloadLedger()
        }
    }
}
