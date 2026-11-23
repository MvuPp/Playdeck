import Charts
import PlaydeckCore
import SwiftUI

/// « Tableau de bord »: deployments per day, grades per project, host states, and the « À traiter » list.
struct DashboardView: View {
    let app: AppModel
    @AppStorage(AppSettings.lintEnabledKey) private var lintEnabled = true

    var body: some View {
        DashboardContent(daily: app.daily, projects: app.projects,
                         lint: app.lintInstalled == false ? .missing : (lintEnabled ? .on : .off),
                         open: { app.selection = .project($0) })
    }
}

enum LintAvailability { case on, off, missing }

/// The dashboard from plain data (also rendered off-screen with sample data).
struct DashboardContent: View {
    let daily: [DayCount]
    let projects: [ProjectModel]
    let lint: LintAvailability
    let open: (String) -> Void

    var body: some View {
        let analyzing = projects.filter(\.analyzing).count
        let todo = projects.flatMap(\.todo)
        // Form rather than ScrollView: same hit-area offset bug as the inspector (see ConfigPanel).
        Form {
            Section {
                HStack {
                    Text("Tableau de bord").font(.title2.bold())
                    Spacer()
                    if analyzing > 0 {
                        ProgressView().controlSize(.small)
                        Text("Analyse en cours (\(analyzing) projet(s))…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if projects.isEmpty {
                Section {
                    ContentUnavailableView("Aucun projet", systemImage: "folder.badge.plus",
                                           description: Text("« Ajouter un dossier » (en bas du menu) : un projet Ansible, ou un dossier qui en contient."))
                }
            } else {
                Section { DailyChart(daily: daily) } header: { Label("Déploiements réels (30 jours)", systemImage: "chart.bar") }
                Section { GradesChart(projects: projects, lint: lint) } header: { Label("Notes ansible-lint par projet", systemImage: "checkmark.seal") }
                Section { HostsChart(projects: projects) } header: { Label("Machines", systemImage: "server.rack") }
                Section {
                    if todo.isEmpty {
                        Label(analyzing > 0 ? "Analyse en cours…" : "Rien à traiter.", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(todo) { item in
                        Button { open(item.projectPath) } label: { TodoRow(item: item) }
                            .buttonStyle(.plain)
                    }
                } header: { Label("À traiter (\(todo.count))", systemImage: "exclamationmark.bubble") }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DailyChart: View {
    let daily: [DayCount]

    var body: some View {
        let ok = daily.map(\.successes).reduce(0, +), ko = daily.map(\.failures).reduce(0, +)
        if ok + ko == 0 {
            ContentUnavailableView("Aucun déploiement réel", systemImage: "chart.bar",
                                   description: Text("Les simulations (--check) ne comptent pas."))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(ok) succès · \(ko) échec(s)").font(.caption).foregroundStyle(.secondary)
                Chart(daily) { d in
                    BarMark(x: .value("Jour", d.day, unit: .day), y: .value("Déploiements", d.successes))
                        .foregroundStyle(by: .value("Résultat", "Succès"))
                        .accessibilityLabel(d.day.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(d.successes) succès")
                    BarMark(x: .value("Jour", d.day, unit: .day), y: .value("Déploiements", d.failures))
                        .foregroundStyle(by: .value("Résultat", "Échec"))
                        .accessibilityLabel(d.day.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(d.failures) échec(s)")
                }
                .chartForegroundStyleScale(["Succès": Color.green, "Échec": Color.red])
                .frame(height: 170)
            }
        }
    }
}

/// One bar per project: its playbooks counted by grade (A green … F red); the project grade in the axis label.
private struct GradesChart: View {
    let projects: [ProjectModel]
    let lint: LintAvailability

    var body: some View {
        let linted = projects.filter { $0.lint != nil }
        switch lint {
        case .missing:
            Label("ansible-lint n'est pas installé : notes indisponibles (voir Réglages).", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        case .off:
            Label("Analyse ansible-lint désactivée (Réglages).", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .on where linted.isEmpty:
            Label(projects.contains(where: \.analyzing) ? "Analyse en cours…" : "Aucune note disponible.", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .on:
            let rows = linted.flatMap { p in
                Dictionary(grouping: p.playbookNames, by: { p.grade($0) ?? .A })
                    .map { (project: "\(p.project.name) (\((p.projectGrade ?? .A).rawValue))", grade: $0.key, count: $0.value.count) }
            }
            Chart(Array(rows.enumerated()), id: \.offset) { _, row in
                BarMark(x: .value("Playbooks", row.count), y: .value("Projet", row.project))
                    .foregroundStyle(by: .value("Note", row.grade.rawValue))
                    .accessibilityLabel(row.project)
                    .accessibilityValue("\(row.count) playbook(s) notés \(row.grade.rawValue)")
            }
            .chartForegroundStyleScale(domain: Grade.allCases.map(\.rawValue), range: Grade.allCases.map(\.color))
            .frame(height: CGFloat(max(linted.count, 2)) * 34 + 30)
        }
        ForEach(projects.filter { lint == .on && $0.lint == nil && $0.lintError != nil }) { p in
            Label("\(p.project.name) : ansible-lint a échoué — \(p.lintError!)", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red).lineLimit(3)
        }
    }
}

/// One bar per project: hosts up to date / behind / never deployed (StateKind colors).
private struct HostsChart: View {
    let projects: [ProjectModel]

    var body: some View {
        let withHosts = projects.filter { $0.counts.total > 0 }
        if withHosts.isEmpty {
            Text("Aucune machine dans les inventaires.").foregroundStyle(.secondary)
        } else {
            let rows = withHosts.flatMap { p in StateKind.allCases.map { (project: p.project.name, kind: $0, count: $0.count(in: p.counts)) } }
            Chart(Array(rows.enumerated()), id: \.offset) { _, row in
                BarMark(x: .value("Machines", row.count), y: .value("Projet", row.project))
                    .foregroundStyle(by: .value("État", row.kind.label))
                    .accessibilityLabel(row.project)
                    .accessibilityValue("\(row.count) \(row.kind.plural)")
            }
            .chartForegroundStyleScale(domain: StateKind.allCases.map(\.label), range: StateKind.allCases.map(\.color))
            .frame(height: CGFloat(max(withHosts.count, 2)) * 34 + 30)
        }
    }
}

private struct TodoRow: View {
    let item: TodoItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).foregroundStyle(item.color).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.title) — \(item.projectName) · \(item.playbook)").fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ouvre le projet")
    }
}
