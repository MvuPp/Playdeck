import PlaydeckCore
import SwiftUI

/// Menu on the left, content in the center (+ batch console at the bottom), actions on the right.
struct RootView: View {
    @Bindable var app: AppModel
    @State private var showActions = true
    @State private var dropTargeted = false
    @State private var dropMessage: String?

    var body: some View {
        NavigationSplitView {
            Sidebar(app: app)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch app.selection {
                    case .project(let path)?:
                        if let p = app.project(path) { ProjectView(app: app, project: p).id(path) }
                    case .dashboard?:
                        DashboardView(app: app)
                    case .settings?:
                        AppSettingsView(app: app)
                    case .history?:
                        HistoryView(app: app)
                    case .help?:
                        HelpView()
                    case .overview?, nil:
                        OverviewView(app: app)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                BatchConsole(app: app)
            }
        }
        // On the split view, not the detail column: inside the detail, macOS 14 can offset the hit areas.
        .inspector(isPresented: $showActions) {
            ConfigPanel(app: app)
                .toolbar {
                    ToolbarItem {
                        Button { showActions.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                            .help("Afficher / masquer la configuration")
                            .accessibilityLabel("Afficher ou masquer la configuration")
                    }
                }
        }
        .navigationTitle("Playdeck")
        // Drag a folder from the Finder anywhere on the window: same as « Ajouter un dossier ».
        .dropDestination(for: URL.self) { urls, _ in
            addDropped(urls)
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        Label("Déposer pour ajouter le dossier", systemImage: "folder.badge.plus")
                            .font(.title3.bold())
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .alert("Dossier non ajouté", isPresented: Binding(get: { dropMessage != nil }, set: { if !$0 { dropMessage = nil } })) {
            Button("OK") { dropMessage = nil }
        } message: { Text(dropMessage ?? "") }
        // An alert (not a confirmationDialog) so it can hold the sudo SecureField.
        .alert("Confirmer le déploiement", isPresented: Binding(get: { app.pending != nil }, set: { if !$0 { app.cancelPending() } }),
               presenting: app.pending) { pending in
            if pending.project.askBecomePassword {
                SecureField("Mot de passe sudo", text: $app.becomePassword)
            }
            Button(pending.check ? "Simuler" : "Déployer") { app.confirm() }
                .disabled(pending.project.askBecomePassword && app.becomePassword.isEmpty)
            Button("Annuler", role: .cancel) { app.cancelPending() }
        } message: { pending in
            Text(message(pending))
        }
    }

    private func message(_ pending: PendingDeploy) -> String {
        let steps = pending.steps
        let version = pending.project.version
        let lines = steps.map { "• \($0.playbook) : " + ($0.hosts.isEmpty ? "ignoré (aucune machine ciblée)" : "\($0.hosts.count) machine(s)") }
        return "\(pending.project.project.name), hash \(version.isEmpty ? "?" : version)"
            + (pending.check ? " — simulation (--check)." : " — déploiement RÉEL.") + "\n\n" + lines.joined(separator: "\n")
            + (pending.options.isDefault ? "" : "\n\nOptions : " + pending.options.arguments.joined(separator: " "))
            + (pending.project.vaultSaved == true ? "\n\nMot de passe ansible-vault : celui du Trousseau." : "")
            + (pending.project.askBecomePassword ? "\n\nSaisissez le mot de passe sudo (gardé en mémoire pour ce déploiement seulement)." : "")
            + (pending.project.gitCommit?.hasSuffix("-dirty") == true ? "\n\n⚠️ Attention : le projet a des modifications non commitées. Ce qui sera déployé ne correspond à aucun commit." : "")
    }

    /// Adds every dropped folder that is (or contains) an Ansible project; explains what was left out.
    private func addDropped(_ urls: [URL]) -> Bool {
        var skipped: [String] = []
        var added = false
        for url in urls {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                skipped.append("« \(url.lastPathComponent) » n'est pas un dossier.")
                continue
            }
            guard !ProjectLibrary.scan(url).isEmpty else {
                skipped.append("« \(url.lastPathComponent) » ne contient aucun projet Ansible (inventaire + playbook).")
                continue
            }
            app.add(url)
            added = true
        }
        if !skipped.isEmpty { dropMessage = skipped.joined(separator: "\n") }
        return added
    }
}
