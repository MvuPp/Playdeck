import PlaydeckCore
import SwiftUI

/// Project header, code-changed banner, playbook checklist and compact host chips.
struct ProjectView: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel
    private var locked: Bool { app.running }  // a batch is running

    var body: some View {
        // Form rather than ScrollView: same hit-area offset bug as the inspector (see ConfigPanel).
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text(project.project.name).font(.title2.bold())
                    VersionPill(project: project)
                    Spacer()
                    if project.loading { ProgressView().controlSize(.small) }
                }
                CounterTiles(counts: project.counts)
                if let error = project.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout).textSelection(.enabled).lineLimit(4)
                }
                if let ledgerError = project.ledgerError {
                    Label(ledgerError, systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red).font(.callout).textSelection(.enabled).lineLimit(4)
                }
                if !project.unreadable.isEmpty {
                    Label("Illisible, le hash peut être faux : " + project.unreadable.prefix(5).joined(separator: ", ")
                          + (project.unreadable.count > 5 ? " (+\(project.unreadable.count - 5))" : ""),
                          systemImage: "eye.slash")
                        .foregroundStyle(.orange).font(.callout).lineLimit(3)
                }
                CodeChangedBanner(project: project, locked: locked)
            }
            Section { DeployBar(app: app, project: project) }
            PlaybookList(project: project).disabled(locked)
            HostChips(project: project).disabled(locked)
        }
        .formStyle(.grouped)
    }
}

/// Shown when hosts were deployed at an older hash: the code changed since, they must be updated.
/// Lists the changed files (from the manifests saved in .playdeck/).
private struct CodeChangedBanner: View {
    @Bindable var project: ProjectModel
    let locked: Bool

    var body: some View {
        let outdated = project.perHost.filter { if case .outdated = $0.value.state { true } else { false } }
        if !outdated.isEmpty {
            let old = Set(project.matrix.filter { outdated[$0.key] != nil }.values.flatMap(\.values).compactMap {
                if case let .outdated(version, _) = $0.state { version } else { nil }
            }).sorted()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.title2).foregroundStyle(.orange)
                        .symbolEffect(.pulse)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Le code a changé — mise à jour nécessaire").font(.headline)
                        Text("Hash actuel \(project.version). \(outdated.count) machine(s) ont été déployées avec une version précédente.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cocher ces machines", systemImage: "checklist") { project.selection.formUnion(outdated.keys) }
                        .buttonStyle(.pill(.orange))
                        .disabled(locked)
                }
                ForEach(old, id: \.self) { hash in
                    ChangeList(hash: hash, changes: project.changes(since: hash))
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// « Depuis abc123 : 3 fichier(s) » + the files (first 8, the rest in a count).
private struct ChangeList: View {
    let hash: String
    let changes: FileChanges?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let changes {
                Text("Depuis \(hash) : \(changes.count) fichier(s) modifié(s)").font(.caption.bold())
                let lines = changes.modified.map { ("pencil", $0) } + changes.added.map { ("plus", $0) } + changes.removed.map { ("minus", $0) }
                ForEach(lines.prefix(8), id: \.1) { symbol, path in
                    Label(path, systemImage: symbol).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
                if lines.count > 8 { Text("… et \(lines.count - 8) autre(s)").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("Depuis \(hash) : détail des fichiers indisponible").font(.caption).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .padding(.leading, 36)
    }
}

/// Deploy from the center: what will run, simulation toggle, the two deploy buttons.
private struct DeployBar: View {
    @Bindable var app: AppModel
    let project: ProjectModel

    var body: some View {
        let steps = BatchDeployService.plan(playbooks: project.playbookNames.filter(project.checked.contains),
                                            hosts: project.selectedHosts, targets: project.targets)
        let pairs = steps.map(\.hosts.count).reduce(0, +)
        let busy = app.running || project.loading
        let color: Color = app.check ? .accentColor : .orange
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(pairs) lancement(s) machine × playbook").font(.headline).contentTransition(.numericText())
                    Text("\(project.selection.count) machine(s) · \(steps.filter { !$0.hosts.isEmpty }.count)/\(steps.count) playbook(s) concernés"
                         + (project.options.isDefault ? "" : " · options actives"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Simulation (--check)", isOn: $app.check).toggleStyle(.switch).controlSize(.small).disabled(app.running)
            }
            HStack(spacing: 10) {
                Button { app.requestDeploy(project, allPlaybooks: false) } label: {
                    Label(app.check ? "Simuler la sélection" : "Déployer la sélection", systemImage: "paperplane.fill")
                }
                .buttonStyle(.action(color, filled: true))
                .disabled(busy || pairs == 0)
                .help("Playbooks cochés sur les machines sélectionnées (chacun sur celles qu'il cible)")
                Button { app.requestDeploy(project, allPlaybooks: true) } label: {
                    Label(app.check ? "Tout simuler" : "Tout déployer", systemImage: "square.stack.3d.up.fill")
                }
                .buttonStyle(.action(color))
                .disabled(busy || project.selection.isEmpty)
                .help("Coche tous les playbooks puis les lance sur les machines sélectionnées (chacun sur celles qu'il cible)")
            }
            if !app.check {
                Label("Déploiement réel : les machines seront modifiées", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.25)))
        .animation(.snappy, value: app.check)
        .animation(.snappy, value: pairs)
    }
}

/// A whole row / tile that toggles on click, with a drawn checkbox: the clickable area is exactly what is drawn.
private struct CheckTile<Label: View>: View {
    let isOn: Bool
    let toggle: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .font(.body)
                    .accessibilityHidden(true)
                label
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isOn ? Color.accentColor.opacity(0.5) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// One checkable row per playbook, with how many hosts it targets and how many must be updated.
private struct PlaybookList: View {
    @Bindable var project: ProjectModel

    var body: some View {
        Section {
            HStack {
                Spacer()
                Button("Tous") { project.checked = Set(project.playbookNames) }.buttonStyle(.pill())
                Button("Aucun") { project.checked = [] }.buttonStyle(.pill(.secondary))
            }
            ForEach(project.playbookNames, id: \.self) { row($0) }
        } header: { Label("Playbooks", systemImage: "doc.text") }
    }

    private func row(_ pb: String) -> some View {
        let on = project.checked.contains(pb)
        let behind = project.matrix.values.compactMap { $0[pb] }.filter { if case .outdated = $0.state { true } else { false } }.count
        return CheckTile(isOn: on, toggle: { if on { project.checked.remove(pb) } else { project.checked.insert(pb) } }) {
            Text(pb).lineLimit(1).truncationMode(.middle)
            Spacer()
            if behind > 0 {
                Text("\(behind) à mettre à jour").font(.caption.bold()).foregroundStyle(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
            }
            Text(project.targets?[pb].map { "\($0.count) machine(s)" } ?? "cibles inconnues")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .help(project.targets?[pb].map { "Cible : " + $0.sorted().joined(separator: ", ") } ?? "Cibles inconnues")
        .accessibilityLabel("Playbook \(pb)")
    }
}

/// Compact host picker: a small tile per host (checkbox, state icon, name); details in the tooltip.
private struct HostChips: View {
    @Bindable var project: ProjectModel

    var body: some View {
        Section {
            HStack {
                Text("\(project.selection.count) sélectionnée(s)").foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer()
                Picker("Groupe", selection: $project.group) {
                    Text("Tous les groupes").tag("")
                    ForEach(project.groups, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
                Button("Retards", systemImage: "checklist") { project.selectBehind() }
                    .buttonStyle(.pill(.orange))
                    .help("Cocher les machines en retard ou jamais déployées")
                    .accessibilityLabel("Sélectionner les machines en retard")
                Button("Tout") { project.selection.formUnion(project.visibleHosts.map(\.name)) }.buttonStyle(.pill())
                Button("Aucune") { project.selection.removeAll() }.buttonStyle(.pill(.secondary))
            }
            if project.hosts.isEmpty && !project.loading {
                ContentUnavailableView("Aucune machine", systemImage: "server.rack",
                                       description: Text("L'inventaire est vide ou n'a pas pu être lu."))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(project.visibleHosts) { chip($0) }
                }
            }
        } header: { Label("Machines", systemImage: "server.rack") }
    }

    private func chip(_ host: PlaydeckCore.Host) -> some View {
        let selected = project.selection.contains(host.name)
        let status = project.perHost[host.name]
        let details = (project.matrix[host.name] ?? [:]).sorted { $0.key < $1.key }
            .map { pb, status in
                var line = "\(pb) : \(StateKind(status.state).label)"
                if case let .outdated(hash, _) = status.state, let c = project.changes(since: hash) { line += " (\(c.count) fichier(s) modifié(s))" }
                return line
            }
        return CheckTile(isOn: selected, toggle: {
            if selected { project.selection.remove(host.name) } else { project.selection.insert(host.name) }
        }) {
            if let status { StatusBadge(status: status, compact: true) }
            Text(host.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
        }
        .help((["Groupes : " + (host.groups.isEmpty ? "—" : host.groups.joined(separator: ", "))] + details).joined(separator: "\n"))
        .accessibilityLabel("\(host.name), \(status.map { StateKind($0.state).label } ?? "état inconnu")")
    }
}
