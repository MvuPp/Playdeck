import PlaydeckCore
import SwiftUI

/// Global tiles + one card per project (version, gauge); a click opens the project.
struct OverviewView: View {
    let app: AppModel

    var body: some View {
        // Form rather than ScrollView: same hit-area offset bug as the inspector (see ConfigPanel).
        Form {
            Section {
                HStack {
                    Text("Vue d'ensemble").font(.title2.bold())
                    Spacer()
                }
                CounterTiles(counts: app.totalCounts)
            }
            Section {
                if app.projects.isEmpty {
                    ContentUnavailableView("Aucun projet", systemImage: "folder.badge.plus",
                                           description: Text("« Ajouter un dossier » (en bas du menu) : un projet Ansible, ou un dossier qui en contient."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                        ForEach(app.projects) { p in
                            Button { app.selection = .project(p.id) } label: { ProjectCard(project: p) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProjectCard: View {
    let project: ProjectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "shippingbox.fill").foregroundStyle(.tint).accessibilityHidden(true)
                Text(project.project.name).font(.headline)
                Spacer()
                if project.loading { ProgressView().controlSize(.small) }
            }
            VersionPill(project: project)
            StatusGauge(counts: project.counts)
            HStack(spacing: 10) {
                ForEach(StateKind.allCases, id: \.self) { kind in
                    let n = kind.count(in: project.counts)
                    if n > 0 {
                        Label("\(n)", systemImage: kind.symbol).foregroundStyle(kind.color).help("\(n) \(kind.plural)")
                    }
                }
                Spacer()
                Text("\(project.hosts.count) machine(s) · \(project.playbookNames.count) playbook(s)").foregroundStyle(.secondary)
            }
            .font(.caption)
            if let error = project.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ouvre le projet")
    }
}

/// Deploy hash (what the machines get) + git commit for information, « non commité » if dirty.
struct VersionPill: View {
    let project: ProjectModel

    var body: some View {
        HStack(spacing: 6) {
            Label(project.version.isEmpty ? "…" : project.version, systemImage: "number")
                .font(.system(.caption, design: .monospaced))
                .contentTransition(.numericText())
                .animation(.snappy, value: project.version)
                .help("Hash des fichiers du projet : noté dans .playdeck/ pour chaque machine déployée")
            if let git = project.gitCommit {
                let dirty = git.hasSuffix("-dirty")
                Text("git " + git.replacingOccurrences(of: "-dirty", with: ""))
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                if dirty {
                    Label("non commité", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                        .help("Modifications non commitées : le hash les inclut, mais aucun commit ne leur correspond.")
                }
            }
        }
    }
}
