import AppKit
import PlaydeckCore
import SwiftUI
import UniformTypeIdentifiers

/// Saved runs (newest first), filterable by project, runs of one batch grouped; selecting one shows its details.
struct HistoryView: View {
    @Bindable var app: AppModel
    @State private var selected: Run.ID?
    @State private var choosingExport = false
    @State private var exportError: String?

    private var runs: [Run] { app.historyFilter.isEmpty ? app.runs : app.runs.filter { $0.projectPath == app.historyFilter } }

    var body: some View {
        let batches = RunStore.batches(runs)
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("Projet", selection: $app.historyFilter) {
                        Text("Tous les projets").tag("")
                        ForEach(Array(Set(app.runs.map(\.projectPath)).union(app.projects.map(\.id))).sorted(), id: \.self) { path in
                            Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                        }
                    }
                    Button { app.reloadRuns() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.icon).help("Rafraîchir").accessibilityLabel("Rafraîchir l'historique")
                    Button("Exporter…", systemImage: "square.and.arrow.up") { choosingExport = true }
                        .buttonStyle(.pill()).disabled(runs.isEmpty)
                        .help("Exporter les déploiements affichés (filtre projet respecté)")
                }
                .padding(8)
                List(selection: $selected) {
                    ForEach(batches, id: \.first!.id) { group in
                        if group.count > 1 {
                            Section {
                                ForEach(group) { RunRow(run: $0, showDate: false).tag($0.id) }
                            } header: {
                                Label("Tout déployer · \(group[0].projectName) · \(group[0].date.formatted(date: .abbreviated, time: .shortened))",
                                      systemImage: "square.stack.3d.up")
                            }
                        } else {
                            RunRow(run: group[0], showDate: true).tag(group[0].id)
                        }
                    }
                }
                .overlay { if runs.isEmpty { ContentUnavailableView("Aucun déploiement enregistré", systemImage: "clock") } }
            }
            .frame(minWidth: 240, idealWidth: 290, maxWidth: 380)
            Group {
                if let run = runs.first(where: { $0.id == selected }) {
                    RunDetail(run: run)
                } else {
                    ContentUnavailableView("Choisissez un déploiement", systemImage: "doc.text.magnifyingglass")
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { app.reloadRuns() }
        .confirmationDialog("Exporter \(runs.count) déploiement(s)", isPresented: $choosingExport) {
            Button("CSV (une ligne par machine)") { export(runs, csv: true, logs: false) }
            Button("JSON") { export(runs, csv: false, logs: false) }
            Button("JSON avec les logs complets") { export(runs, csv: false, logs: true) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le JSON sans logs garde tout le reste des déploiements. Aucun mot de passe n'est enregistré dans l'historique, "
                 + "mais les logs contiennent ce que les playbooks ont affiché : une valeur du vault montrée par debug, --diff ou -v y figure en clair.")
        }
        .alert("Export impossible", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") {}
        } message: { Text(exportError ?? "") }
    }

    /// Save panel, then writes the given runs (the ones displayed, captured when the user chose the format).
    private func export(_ runs: [Run], csv: Bool, logs: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        let scope = app.historyFilter.isEmpty ? "" : "-" + URL(fileURLWithPath: app.historyFilter).lastPathComponent
        panel.nameFieldStringValue = "playdeck-historique\(scope).\(csv ? "csv" : "json")"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = csv ? Data(RunExport.csv(runs).utf8) : try RunExport.json(runs, includeLogs: logs)
                try data.write(to: url, options: .atomic)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

private struct RunRow: View {
    let run: Run
    let showDate: Bool

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: run.failed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(run.failed ? .red : .green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(showDate ? run.date.formatted(date: .abbreviated, time: .standard) : run.playbook).bold().lineLimit(1)
                    if run.checkMode { Text("simulation").font(.caption).foregroundStyle(.secondary) }
                }
                Text(showDate ? "\(run.projectName) · \(run.playbook) · \(run.version)" : run.version).font(.caption).lineLimit(1)
                Text(run.summary).font(.caption).foregroundStyle(run.failed ? .red : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RunDetail: View {
    let run: Run

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(run.projectName) — \(run.playbook)").font(.title3.bold())
            Text("Hash \(run.version) · \(run.checkMode ? "simulation (--check)" : "déploiement réel") · code \(run.exitCode)"
                 + (run.cancelled ? " · annulé" : ""))
                .foregroundStyle(.secondary)
            Text(run.projectPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let options = run.options {
                Text("Options : " + options.arguments.joined(separator: " "))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let ledgerError = run.ledgerError {
                Text("Hash non noté dans .playdeck/ : \(ledgerError)").foregroundStyle(.red).textSelection(.enabled).lineLimit(6)
            }
            Table(run.results) {
                TableColumn("Machine", value: \.host)
                TableColumn("Statut") { ResultBadge(result: $0) }
                TableColumn("ok") { Text("\($0.ok)") }
                TableColumn("changed") { Text("\($0.changed)") }
                TableColumn("unreachable") { Text("\($0.unreachable)") }
                TableColumn("failed") { Text("\($0.failed)") }
                TableColumn("skipped") { Text("\($0.skipped)") }
            }
            .frame(minHeight: 100, maxHeight: 180)
            LogConsole(lines: run.log).clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding()
    }
}
