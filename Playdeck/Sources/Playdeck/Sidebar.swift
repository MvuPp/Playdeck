import PlaydeckCore
import SwiftUI

/// Left menu: overview, settings, history, then one « Projets » section with every project (« late hosts » pill), add / remove / re-scan.
struct Sidebar: View {
    @Bindable var app: AppModel
    @State private var importing = false

    var body: some View {
        List(selection: $app.selection) {
            Label("Vue d'ensemble", systemImage: "square.grid.2x2").tag(SidebarItem.overview)
            Label("Tableau de bord", systemImage: "chart.bar.xaxis").tag(SidebarItem.dashboard)
            Label("Réglages", systemImage: "gearshape").tag(SidebarItem.settings)
            Label("Historique", systemImage: "clock.arrow.circlepath").tag(SidebarItem.history)
            Label("Aide", systemImage: "questionmark.circle").tag(SidebarItem.help)
            Section("Projets") {
                let projects = app.projects.sorted { $0.project.name.localizedStandardCompare($1.project.name) == .orderedAscending }
                let names = Dictionary(grouping: projects, by: \.project.name)
                ForEach(projects) { p in
                    // The parent folder is shown only when two projects share a name.
                    ProjectRow(project: p, showFolder: (names[p.project.name]?.count ?? 0) > 1)
                        .tag(SidebarItem.project(p.id))
                        .help(p.id)
                }
                if projects.isEmpty {
                    Text("Aucun projet Ansible").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Ajouter un dossier", systemImage: "folder.badge.plus") { importing = true }
                        .buttonStyle(.pill())
                    Spacer()
                    Menu {
                        ForEach(app.folders, id: \.folder) { group in
                            Button(group.folder.path) { app.remove(group.folder) }
                        }
                    } label: { Image(systemName: "folder.badge.minus") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(app.folders.isEmpty)
                        .help("Retirer un dossier")
                        .accessibilityLabel("Retirer un dossier")
                    Button { app.rescan(); app.reloadAll() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.icon)
                        .help("Re-scanner les dossiers")
                        .accessibilityLabel("Re-scanner les dossiers")
                }
                Text(app.ansibleVersion).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(10)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { app.add(url) }
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectModel
    var showFolder = false

    var body: some View {
        HStack {
            Label {
                Text(project.project.name)
                if showFolder {
                    Text(project.project.url.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "shippingbox") }
            Spacer()
            if project.loading {
                ProgressView().controlSize(.mini)
            } else if project.counts.behind > 0 {
                Text("\(project.counts.behind)")
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.orange, in: Capsule())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .help("Machines en retard ou jamais déployées")
                    .accessibilityLabel("\(project.counts.behind) machine(s) en retard")
            } else if project.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).accessibilityLabel("Erreur")
            }
        }
        .animation(.snappy, value: project.counts.behind)
    }
}
