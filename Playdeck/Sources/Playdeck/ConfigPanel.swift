import PlaydeckCore
import SwiftUI

/// Right inspector = configuration of the selected project's runs (-e, tags, --diff, verbosity), command preview, last run.
struct ConfigPanel: View {
    @Bindable var app: AppModel

    var body: some View {
        // A Form, not a ScrollView: in an inspector, a SwiftUI ScrollView's hit areas sit a toolbar-height above
        // what is drawn (macOS 14); the AppKit-backed Form lays out and hit-tests correctly.
        Form {
            if case .project(let path)? = app.selection, let p = app.project(path) {
                ProjectConfig(app: app, project: p).disabled(app.running)
            } else {
                Section("Configuration") {
                    Text("Choisissez un projet dans le menu pour régler ses options de déploiement.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let run = app.runs.first {
                    Section("Dernier run") { LastRunSummary(runs: RunStore.batches(app.runs).first ?? [run]) }
                }
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 260, ideal: 290, max: 380)
    }
}

private struct ProjectConfig: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel

    var body: some View {
        Section {
            HStack {
                Label("Configuration", systemImage: "slider.horizontal.3").font(.headline)
                Spacer()
                Button("Réinitialiser") { project.options = DeployOptions() }
                    .buttonStyle(.pill(.secondary))
                    .disabled(project.options == DeployOptions())
            }
        }

        section("Variables (-e)", systemImage: "curlybraces") {
            // Bindings by id, not `ForEach($…)`: an index-based binding still read by a text field after its row is
            // removed crashes (index out of range).
            ForEach(project.options.variables) { v in
                HStack(spacing: 6) {
                    TextField("Clé", text: variable(v.id, \.key), prompt: Text("clé")).labelsHidden().frame(maxWidth: 100)
                    Text("=").foregroundStyle(.secondary)
                    TextField("Valeur", text: variable(v.id, \.value), prompt: Text("valeur")).labelsHidden()
                    Button("Supprimer", systemImage: "minus.circle.fill") {
                        NSApp.keyWindow?.makeFirstResponder(nil)  // end editing before the field disappears
                        project.options.variables.removeAll { $0.id == v.id }
                    }
                        .buttonStyle(.icon)
                        .accessibilityLabel("Supprimer la variable \(v.key)")
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
            }
            Button("Ajouter une variable", systemImage: "plus") {
                withAnimation(.snappy) { project.options.variables.append(.init()) }
            }
            .buttonStyle(.pill())
            Text("Passées en un seul -e JSON : espaces et guillemets conservés, valeurs en texte. Pas de mot de passe ici : "
                 + "les variables sont gardées en clair (réglages, historique, export) ; utilisez le mot de passe vault.")
                .font(.caption2).foregroundStyle(.secondary)
        }

        section("Tags", systemImage: "tag") {
            TextField("--tags", text: $project.options.tags, prompt: Text("web,db"))
            TextField("--skip-tags", text: $project.options.skipTags, prompt: Text("slow"))
        }
        .textFieldStyle(.roundedBorder)

        section("Options", systemImage: "gearshape") {
            Toggle("Afficher les différences (--diff)", isOn: $project.options.diff)
            if project.vaultSaved == true, project.options.diff || project.options.verbosity > 0 {
                Label("Avec le vault, --diff et -v peuvent afficher des valeurs déchiffrées : elles seront gardées dans le log de l'historique.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Picker("Verbosité", selection: $project.options.verbosity) {
                Text("Normale").tag(0)
                ForEach(1...4, id: \.self) { Text("-" + String(repeating: "v", count: $0)).tag($0) }
            }
        }

        SecretsSection(app: app, project: project)

        section("Commande", systemImage: "terminal") {
            Text(preview)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }

        section("Dernier run", systemImage: "clock") {
            if let last = RunStore.batches(project.runs).first { LastRunSummary(runs: last) } else {
                Text("Aucun déploiement").font(.callout).foregroundStyle(.secondary)
            }
            Button("Historique du projet", systemImage: "clock.arrow.circlepath") {
                app.historyFilter = project.id
                app.selection = .history
            }
            .buttonStyle(.pill())
        }
    }

    /// Binding to one field of the variable `id`; reads "" and ignores writes once that variable is gone.
    private func variable(_ id: UUID, _ field: WritableKeyPath<DeployOptions.Variable, String>) -> Binding<String> {
        Binding(get: { project.options.variables.first { $0.id == id }?[keyPath: field] ?? "" },
                set: { new in
                    if let i = project.options.variables.firstIndex(where: { $0.id == id }) { project.options.variables[i][keyPath: field] = new }
                })
    }

    /// What one playbook of the batch will run (playbook and --limit vary per step).
    private var preview: String {
        (["ansible-playbook", "-i", project.project.relativePath(project.project.inventory), "<playbook>", "--limit", "<machines>"]
         + (app.check ? ["--check"] : []) + project.options.arguments.map { $0.contains(" ") || $0.contains("\"") ? "'\($0)'" : $0 }
         + (project.vaultSaved == true ? ["--vault-password-file", "<script>"] : [])
         + (project.askBecomePassword ? ["--become-password-file", "<script>"] : []))
            .joined(separator: " ")
    }

    private func section(_ title: String, systemImage: String, @ViewBuilder content: () -> some View) -> some View {
        Section { content() } header: { Label(title, systemImage: systemImage) }
    }
}

/// ansible-vault password (Keychain) and the « ask sudo password » flag. Shows only whether a password is saved.
private struct SecretsSection: View {
    let app: AppModel
    @Bindable var project: ProjectModel
    @State private var typed = ""
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent("Mot de passe vault") {
                Text(project.vaultSaved == true ? "enregistré" : "aucun")
                    .foregroundStyle(project.vaultSaved == true ? .green : .secondary)
            }
            HStack(spacing: 6) {
                SecureField("Mot de passe vault", text: $typed, prompt: Text(project.vaultSaved == true ? "nouveau mot de passe" : "mot de passe"))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Enregistrer", action: save).buttonStyle(.pill()).disabled(typed.isEmpty)
            }
            if project.vaultSaved == true {
                Button("Supprimer le mot de passe vault", systemImage: "trash") { store(nil) }
                    .buttonStyle(.pill(.secondary))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Gardé dans le Trousseau macOS, passé à Ansible par --vault-password-file.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Demander le mot de passe sudo", isOn: $project.askBecomePassword)
            Text("Saisi à chaque confirmation, gardé en mémoire pour ce déploiement seulement (--become-password-file).")
                .font(.caption2).foregroundStyle(.secondary)
        } header: { Label("Secrets", systemImage: "key") }
        .task(id: project.id) {
            if project.vaultSaved == nil { project.vaultSaved = app.passwords.hasPassword(for: project.id) }
        }
    }

    private func save() { if !typed.isEmpty { store(typed) } }

    private func store(_ password: String?) {
        do {
            try app.passwords.setPassword(password, for: project.id)
            project.vaultSaved = password != nil
            error = nil
        } catch { self.error = error.localizedDescription }
        typed = ""
    }
}

/// Date, mode and per-playbook outcome of one batch (or single run).
struct LastRunSummary: View {
    let runs: [Run]

    var body: some View {
        if let first = runs.first {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: runs.contains(where: \.failed) ? "xmark.octagon.fill" : "checkmark.seal.fill")
                        .foregroundStyle(runs.contains(where: \.failed) ? .red : .green)
                        .accessibilityHidden(true)
                    Text(first.date.formatted(date: .abbreviated, time: .shortened)).bold()
                }
                Text("\(first.projectName) · \(first.checkMode ? "simulation" : "réel") · \(first.version)")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(runs) { run in
                    HStack {
                        Text(run.playbook).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(run.summary).foregroundStyle(run.failed ? .red : .secondary)
                    }
                    .font(.caption)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
