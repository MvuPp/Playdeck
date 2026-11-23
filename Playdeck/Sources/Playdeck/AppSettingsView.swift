import PlaydeckCore
import SwiftUI

/// App-wide preferences (UserDefaults). Views bind them with @AppStorage using the same keys and defaults.
enum AppSettings {
    static let watchCodeKey = "watchCode", watchIntervalKey = "watchIntervalSeconds"
    static let defaultCheckKey = "defaultCheck", notifyKey = "notifyOnFinish"

    private static func bool(_ key: String, _ fallback: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback }
    private static func int(_ key: String, _ fallback: Int) -> Int { UserDefaults.standard.object(forKey: key) as? Int ?? fallback }

    static var watchCode: Bool { bool(watchCodeKey, true) }
    static var watchInterval: Int { max(int(watchIntervalKey, 5), 1) }
    static var defaultCheck: Bool { bool(defaultCheckKey, true) }
    static var notify: Bool { bool(notifyKey, true) }
}

/// « Réglages » tab: code watch, deploy defaults, Ansible path, project folders.
struct AppSettingsView: View {
    @Bindable var app: AppModel
    @AppStorage(AppSettings.watchCodeKey) private var watchCode = true
    @AppStorage(AppSettings.watchIntervalKey) private var watchInterval = 5
    @AppStorage(AppSettings.defaultCheckKey) private var defaultCheck = true
    @AppStorage(AppSettings.notifyKey) private var notify = true
    @AppStorage(AnsibleLocator.settingsKey) private var ansiblePath = ""
    @State private var importing = false

    var body: some View {
        Form {
            Section {
                Text("Réglages").font(.title2.bold())
            }

            Section {
                Toggle("Détecter les modifications du code", isOn: $watchCode)
                Picker("Fréquence de vérification", selection: $watchInterval) {
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) s").tag($0) }
                }
                .disabled(!watchCode)
            } header: { Label("Surveillance du code", systemImage: "number") } footer: {
                Text("Recalcule le hash des projets : si le code change, les machines déjà déployées passent « en retard ». Relit aussi .playdeck/ (déploiements arrivés par git).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Simulation (--check) cochée au lancement", isOn: $defaultCheck)
                Toggle("Prévenir en fin de déploiement si l'app est en arrière-plan", isOn: $notify)
            } header: { Label("Déploiement", systemImage: "paperplane") } footer: {
                Text("Après un déploiement réel réussi, le hash est noté dans le dossier .playdeck/ du projet (rien n'est écrit sur les machines). L'avis de fin = notification système (via osascript), pastille et rebond du Dock.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Chemin", text: $ansiblePath, prompt: Text("détection automatique"))
                LabeledContent("Version détectée", value: app.ansibleVersion)
            } header: { Label("Ansible", systemImage: "terminal") } footer: {
                Text("Dossier d'Ansible ou chemin de ansible-playbook. Pris en compte au prochain lancement de l'app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(app.folders, id: \.folder) { group in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.folder.lastPathComponent).fontWeight(.medium)
                            Text("\(group.folder.path) · \(group.projects.count) projet(s)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Retirer", systemImage: "minus.circle") { app.remove(group.folder) }
                            .buttonStyle(.pill(.red))
                            .accessibilityLabel("Retirer le dossier \(group.folder.lastPathComponent)")
                    }
                }
                HStack {
                    Button("Ajouter un dossier", systemImage: "folder.badge.plus") { importing = true }.buttonStyle(.pill())
                    Button("Re-scanner", systemImage: "arrow.clockwise") { app.rescan(); app.reloadAll() }.buttonStyle(.pill(.secondary))
                }
            } header: { Label("Dossiers de projets", systemImage: "folder") }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { app.add(url) }
        }
    }
}
