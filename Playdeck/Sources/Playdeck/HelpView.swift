import SwiftUI

/// « Aide »: how Playdeck works and why it makes its choices. Keep in sync with PlaydeckCore when a rule changes.
struct HelpView: View {
    var body: some View {
        Form {
            Section {
                Text("Aide").font(.title2.bold())
                Text("Playdeck lance vos playbooks Ansible sans ligne de commande. Cette page explique comment il décide de ce qu'il affiche.")
                    .foregroundStyle(.secondary)
            }

            topic("Déployer", "paperplane") {
                point("Projets", "Un dossier ajouté qui contient un inventaire et au moins un playbook (un fichier YAML avec `hosts:`) est un projet. Un dossier qui en contient plusieurs les ajoute tous.")
                point("Qui reçoit quoi", "Chaque playbook ne part que sur les machines de sa ligne `hosts:` (lue avec `ansible-playbook --list-hosts`), parmi celles que vous avez cochées. Les playbooks sont indépendants : une machine en échec sur l'un reçoit quand même les autres.")
                point("Simulation", "Cochée par défaut : `--check` montre ce qui changerait sans rien modifier. Une confirmation est toujours demandée avant de lancer.")
                point("Options", "Variables `-e` (envoyées en un seul JSON pour garder espaces et guillemets), `--tags`, `--skip-tags`, `--diff` et verbosité, dans le panneau de droite. Elles sont gardées en clair : pas de mot de passe dedans.")
            }

            topic("Suivi des versions", "number") {
                point("Hash du code", "Empreinte SHA-256 de tous les fichiers du projet. Toute modification la change, commitée ou non. Exclus : `.git`, `.playdeck/`, `logs/` à la racine, le `log_path` d'ansible.cfg, `*.retry`, `.DS_Store`. Les liens symboliques sont suivis.")
                point("Dossier .playdeck/", "Après un déploiement réel réussi, Playdeck note dans le projet le hash déployé sur chaque machine, et la liste des fichiers à ce moment-là. Rien n'est écrit sur les machines. Committez `.playdeck/` pour partager l'état avec d'autres postes.")
                point("États", "À jour : hash noté = hash actuel. En retard : déployée avec une version précédente (les fichiers changés depuis sont listés). Jamais déployée : rien de noté. Une machine prend le pire état de ses playbooks.")
                point("Limite", "Un déploiement fait hors de Playdeck, ou depuis une copie du projet non synchronisée, n'est pas connu.")
            }

            topic("Note qualité (A à F)", "checkmark.seal") {
                point("Source", "ansible-lint (s'il est installé), relancé seulement quand le code change, sans jamais bloquer un déploiement.")
                point("Calcul", "Chaque problème vaut 5 points si sa règle est une erreur, 2 si c'est un avertissement, 1 sinon. A = 0 point, B ≤ 4, C ≤ 14, D ≤ 29, E ≤ 49, F ≥ 50. Le total est absolu : un gros projet a plus de chances d'en accumuler.")
                point("Syntaxe", "`ansible-playbook --syntax-check` est toujours lancé. Un playbook qui échoue ne peut pas tourner : il est noté F, et son projet aussi.")
                point("Rôles", "Un playbook compte les problèmes de son fichier et ceux des rôles qu'il cite par leur nom (`roles:`, `include_role`, `import_role`). Le reste (variables, rôles non cités) compte seulement pour la note du projet. Les dépendances de `meta/main.yml` ne sont pas suivies.")
            }

            topic("Fiabilité", "chart.bar.xaxis") {
                point("Taux de succès", "Part des déploiements réels réussis sur 7 et 30 jours. Les simulations et les lancements annulés ne comptent pas.")
                point("Idempotence", "Relancer un playbook sur un code inchangé ne devrait rien modifier. Une machine est signalée « non idempotente » si, sur au moins deux déploiements réels réussis au même hash, elle a eu des changements à chaque fois.")
            }

            topic("Sécurité", "key") {
                point("Mot de passe vault", "Rangé dans le Trousseau macOS, un par projet. L'app n'affiche jamais sa valeur.")
                point("Mot de passe sudo", "Demandé à la confirmation si l'option est activée pour le projet, gardé en mémoire le temps du déploiement, jamais enregistré.")
                point("Transmission", "Ansible lit les mots de passe via un petit script temporaire qui ne les contient pas : il les reçoit par une variable d'environnement du seul processus Ansible, puis il est supprimé. Un playbook qui affiche une valeur déchiffrée (`debug`, `--diff`, `-v`) la laisse en clair dans l'historique.")
            }

            topic("Historique", "clock.arrow.circlepath") {
                point("Contenu", "Chaque lancement (réussi, en échec ou annulé) est enregistré sur ce Mac avec son log, ses options et le résultat de chaque machine. Export CSV ou JSON depuis l'onglet Historique.")
            }
        }
        .formStyle(.grouped)
    }

    private func topic(_ title: String, _ symbol: String, @ViewBuilder content: () -> some View) -> some View {
        Section { content() } header: { Label(title, systemImage: symbol) }
    }

    private func point(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(.init(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
