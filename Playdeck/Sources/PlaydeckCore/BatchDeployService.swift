import Foundation

public enum BatchEvent: Sendable, Equatable {
    /// Playbook `index` (0-based) of `count` starts on `hosts`.
    case playbookStarted(index: Int, count: Int, playbook: String, hosts: [String])
    /// Playbook `index` skipped: none of the selected hosts is in its `hosts:`.
    case playbookSkipped(index: Int, count: Int, playbook: String)
    /// One log line (ansible-playbook output or a `— … —` status line from the batch).
    case line(String)
    /// Playbook `index` ended; `run` is the saved record (successful hosts recorded in .playdeck/ if real).
    case playbookFinished(index: Int, run: Run)
}

/// A running sequence of playbooks: events, cancel, final runs.
public final class BatchDeployment: @unchecked Sendable {
    /// `Run.batchID` of every run of this batch.
    public let id = UUID()
    /// Finishes when the batch ends.
    public let events: AsyncStream<BatchEvent>
    fileprivate let continuation: AsyncStream<BatchEvent>.Continuation
    private let lock = NSLock()
    private var cancelled = false
    private var current: Deployment?
    private var task: Task<[Run], Never>?

    fileprivate init() { (events, continuation) = AsyncStream.makeStream() }

    fileprivate func setTask(_ task: Task<[Run], Never>) { lock.withLock { self.task = task } }

    /// Stops the current playbook (whole process group) and skips the following ones.
    public func cancel() {
        let running = lock.withLock { cancelled = true; return current }
        running?.cancel()
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Records the running playbook; false (and nothing recorded) if the batch was cancelled meanwhile.
    fileprivate func setCurrent(_ deployment: Deployment?) -> Bool {
        lock.withLock {
            if cancelled, deployment != nil { return false }
            current = deployment
            return true
        }
    }

    /// Waits for the end; one `Run` per playbook actually started (events are buffered even if nobody reads them).
    public func result() async -> [Run] { await lock.withLock { task! }.value }
}

/// One playbook of a batch and the hosts it will run on (empty = skipped).
public struct BatchStep: Sendable, Equatable {
    public let playbook: String
    public let hosts: [String]
}

public enum BatchDeployService {
    /// `--limit` of each playbook (relative paths): selected `hosts` ∩ `targets[playbook]` (nil targets = no filter).
    /// The sum of `hosts.count` is the number of (host, playbook) pairs actually deployed.
    public static func plan(playbooks: [String], hosts: [String], targets: [String: Set<String>]?) -> [BatchStep] {
        playbooks.map { pb in BatchStep(playbook: pb, hosts: targets.map { t in hosts.filter { t[pb]?.contains($0) == true } } ?? hosts) }
    }

    /// Runs `playbooks` one after the other (sequential, order without meaning) via `DeployService`. Playbooks are
    /// independent: each runs with `--limit` = selected `hosts` ∩ `targets[relative path]` (from `PlaybookTargets.load`),
    /// and is skipped when that is empty; a host failing one playbook still gets the others. `targets == nil` = no
    /// filtering (every playbook on every selected host). Stops on cancel or if ansible-playbook cannot start.
    /// The hash is taken from the files when the batch starts. After each real (not `--check`), non-cancelled playbook,
    /// its successful hosts are recorded in the project's `.playdeck/` (`DeployLedger`); nothing is written on the hosts.
    /// Each started playbook is saved in `store` as one `Run` with the batch's `batchID`, whatever its outcome.
    /// `secrets` (vault / become passwords) reach each ansible-playbook via `SecretScripts`, never the `Run`.
    public static func start(tools: AnsibleTools, project: AnsibleProject, playbooks: [URL], hosts: [String],
                             targets: [String: Set<String>]?, check: Bool, options: DeployOptions = .init(),
                             store: RunStore = RunStore(), secrets: DeploySecrets = .init()) -> BatchDeployment {
        let batch = BatchDeployment()
        let cont = batch.continuation
        batch.setTask(Task {
            var runs: [Run] = []
            let manifest = project.manifest()
            let version = AnsibleProject.hash(manifest)
            let ledger = DeployLedger(project: project)
            let steps = plan(playbooks: playbooks.map(project.relativePath), hosts: hosts, targets: targets)
            for (index, (playbook, step)) in zip(playbooks, steps).enumerated() {
                if batch.isCancelled { break }
                let (rel, limit) = (step.playbook, step.hosts)
                if limit.isEmpty {
                    cont.yield(.playbookSkipped(index: index, count: playbooks.count, playbook: rel))
                    cont.yield(.line("— \(rel) : aucune machine sélectionnée n'est ciblée, ignoré —"))
                    continue
                }
                cont.yield(.playbookStarted(index: index, count: playbooks.count, playbook: rel, hosts: limit))
                let date = Date()
                let deployment: Deployment
                do {
                    deployment = try DeployService.start(tools: tools, project: project, playbook: playbook, hosts: limit, check: check,
                                                            options: options, secrets: secrets)
                } catch {
                    cont.yield(.line("— Impossible de lancer ansible-playbook : \(error.localizedDescription) —"))
                    break
                }
                if !batch.setCurrent(deployment) { deployment.cancel() }
                for await line in deployment.lines { cont.yield(.line(line)) }
                let result = await deployment.result()
                _ = batch.setCurrent(nil)
                if result.cancelled { cont.yield(.line("— Déploiement annulé —")) }

                var run = Run(date: date, projectPath: project.url.path, playbook: rel, version: version, hosts: limit,
                              checkMode: check, exitCode: result.exitCode, cancelled: result.cancelled,
                              results: result.hosts, log: result.log, batchID: batch.id,
                              options: options.isDefault ? nil : options)
                let succeeded = result.hosts.filter { $0.status == .success }.map(\.host)
                if !check, !result.cancelled, !succeeded.isEmpty {
                    do {
                        try ledger.record(hosts: succeeded, playbook: rel, hash: version, manifest: manifest, date: date)
                        cont.yield(.line("— Hash \(version) noté dans \(DeployLedger.directoryName)/ pour \(succeeded.count) machine(s) —"))
                    } catch {
                        run.ledgerError = error.localizedDescription
                        cont.yield(.line("— Hash NON noté dans \(DeployLedger.directoryName)/ : \(error.localizedDescription) —"))
                    }
                }
                do { try store.save(run) } catch { cont.yield(.line("— Historique non enregistré : \(error.localizedDescription) —")) }
                runs.append(run)
                cont.yield(.playbookFinished(index: index, run: run))
                if result.cancelled { break }
            }
            cont.finish()
            return runs
        })
        return batch
    }
}
