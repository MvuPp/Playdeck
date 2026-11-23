import AppKit
import PlaydeckCore
import SwiftUI

@main
struct PlaydeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        Self.migrateFromAnsibleDeploy()
        // `swift run` launches a bare executable: make it a regular foreground app with a window.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // One window: a second one would be a second AppModel, able to run a batch on the same project in parallel.
        Window("Playdeck", id: "main") { ContentView() }
        Settings { SettingsView() }
    }

    /// One-time import of what was saved under the app's former name « AnsibleDeploy »: preferences (folders,
    /// per-project options, settings) and the run history folder.
    private static func migrateFromAnsibleDeploy() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "migratedFromAnsibleDeploy") {
            // NS* keys are window frames tied to the old type names: not worth keeping.
            for (key, value) in defaults.persistentDomain(forName: "AnsibleDeploy") ?? [:] where !key.hasPrefix("NS") {
                defaults.set(value, forKey: key)
            }
            defaults.set(true, forKey: "migratedFromAnsibleDeploy")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("AnsibleDeploy"), new = support.appendingPathComponent("Playdeck")
        if FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: new.path) {
            try? FileManager.default.moveItem(at: old, to: new)
        }
    }
}

/// Quitting during a batch would leave ansible-playbook running orphaned (secrets in its environment), with neither
/// the run nor .playdeck/ written: ask, then cancel the batch and wait for it to end before quitting.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let app = AppModel.current, app.running else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "Un déploiement est en cours"
            alert.informativeText = "Quitter annule le déploiement : les machines peuvent rester à moitié configurées."
            alert.addButton(withTitle: "Continuer le déploiement")
            alert.addButton(withTitle: "Annuler et quitter")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            app.batch?.deployment.cancel()
            Task { @MainActor in
                let deadline = Date().addingTimeInterval(15)
                while app.running, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}

struct ContentView: View {
    @AppStorage(AnsibleLocator.settingsKey) private var savedPath = ""
    @State private var state: LoadState = .loading

    enum LoadState { case loading, missing, failed(String), ok(AppModel) }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Recherche d'Ansible…")
            case .missing:
                MissingPrerequisitesView(retry: { Task { await load() } })
            case .failed(let message):
                ContentUnavailableView("`ansible --version` a échoué", systemImage: "exclamationmark.triangle", description: Text(message))
            case .ok(let app):
                RootView(app: app)
            }
        }
        .frame(minWidth: 1000, minHeight: 650)
        // Once at launch (and on « Réessayer »), not on every keystroke in the Ansible path field: rebuilding the
        // AppModel would drop a running batch's console and its single-batch guard.
        .task { await load() }
    }

    private func load() async {
        state = .loading
        let saved = savedPath
        guard let tools = await Task.detached(operation: { AnsibleLocator.locate(savedPath: saved) }).value else {
            state = .missing
            return
        }
        do {
            let version = try await AnsibleLocator.version(tools)
            state = .ok(AppModel(tools: tools, ansibleVersion: version.split(separator: "\n").first.map(String.init) ?? ""))
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

struct MissingPrerequisitesView: View {
    let retry: () -> Void
    private let command = "brew install ansible"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.largeTitle)
            Text("Prérequis manquants").font(.title2.bold())
            Text("Ansible est introuvable. Installez-le dans un terminal :")
            HStack {
                Text(command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Button("Copier", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .buttonStyle(.pill())
            }
            Link("Documentation d'installation", destination: URL(string: "https://docs.ansible.com/ansible/latest/installation_guide/index.html")!)
            Text("Ou indiquez son dossier dans Réglages (⌘,).").foregroundStyle(.secondary)
            Button("Réessayer", systemImage: "arrow.clockwise", action: retry)
                .buttonStyle(.action(filled: true))
                .frame(maxWidth: 220)
        }
        .padding()
    }
}

struct SettingsView: View {
    @AppStorage(AnsibleLocator.settingsKey) private var savedPath = ""

    var body: some View {
        Form {
            TextField("Dossier d'Ansible (ou chemin de ansible-playbook)", text: $savedPath, prompt: Text("détection automatique"))
        }
        .padding()
        .frame(width: 480)
    }
}
